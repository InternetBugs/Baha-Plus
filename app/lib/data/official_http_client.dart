import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../core/community.dart';
import '../core/models.dart';
import 'native_http_api.dart';

/// Account HTTP operations import the device's official cookies into memory.
/// Neither a browser document nor JavaScript is needed. Playback imports a
/// separate snapshot and never shares this client's mutable session.
class OfficialHttpClient {
  OfficialHttpClient({
    http.Client? client,
    Future<NativeHttpCookieJar> Function()? cookieLoader,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client(),
       _cookieLoader = cookieLoader ?? loadCookies;

  static const hosts = {
    'ani.gamer.com.tw',
    'api.gamer.com.tw',
    'wall.gamer.com.tw',
  };
  static final _cookieURLs = [
    Uri.https('ani.gamer.com.tw', '/mygather.php'),
    Uri.https('ani.gamer.com.tw', '/ajax/getCSRFToken.php'),
    Uri.https('api.gamer.com.tw', '/anime/v3/history.php'),
    Uri.https('wall.gamer.com.tw', '/app/v1/comment_new.php'),
  ];
  static const _getPaths = {
    'ani.gamer.com.tw': {
      '/mygather.php',
      '/search.php',
      '/animeVideo.php',
      '/ajax/getCSRFToken.php',
    },
    'api.gamer.com.tw': {'/anime/v3/history.php', '/ajax/common/topBar.php'},
    'wall.gamer.com.tw': {
      '/app/v2/comment_detail.php',
      '/app/v1/reply_detail.php',
    },
  };
  static const _postPaths = {
    'ani.gamer.com.tw': {'/ajax/want2play.php', '/ajax/delgather.php'},
    'wall.gamer.com.tw': {
      '/app/v1/comment_new.php',
      '/app/v1/comment_like.php',
      '/app/v1/comment_like_del.php',
    },
  };
  final http.Client _client;
  final Future<NativeHttpCookieJar> Function() _cookieLoader;
  final Duration timeout;
  final _requests = <Completer<void>>{};
  int _generation = 0;
  bool _disposed = false;

  static Future<NativeHttpCookieJar> loadPlaybackCookies() =>
      loadCookies(urls: NativeHttpApi.cookieURLs);

  static Future<NativeHttpCookieJar> loadCookies({List<Uri>? urls}) async {
    final jar = NativeHttpCookieJar(allowedHosts: hosts);
    final manager = CookieManager.instance();
    for (final uri in urls ?? _cookieURLs) {
      for (final cookie in await manager.getCookies(
        url: WebUri(uri.toString()),
      )) {
        final name = cookie.name, value = '${cookie.value}';
        final path = cookie.path ?? '/';
        final domain = cookie.domain
            ?.replaceFirst(RegExp(r'^\.'), '')
            .toLowerCase();
        if (!RegExp(r'^[!#$%&*+\-.^_`|~0-9A-Za-z]+$').hasMatch(name) ||
            value.contains(RegExp(r'[\x00-\x20\x7f";,\\]')) ||
            !path.startsWith('/') ||
            path.contains(RegExp(r'[;\r\n]')) ||
            (domain != null &&
                domain != 'gamer.com.tw' &&
                domain != uri.host) ||
            (cookie.expiresDate != null &&
                cookie.expiresDate! <= DateTime.now().millisecondsSinceEpoch)) {
          continue;
        }
        jar.receive(
          uri,
          '$name=$value; Path=$path${domain == null ? '' : '; Domain=$domain'}',
        );
      }
    }
    return jar;
  }

  static String _fingerprint(NativeHttpCookieJar cookies) => _cookieURLs
      .map((uri) {
        final values = cookies.header(uri).split('; ')
          ..removeWhere((cookie) => cookie.startsWith('ckBahamutCsrfToken='))
          ..sort();
        return values.join('; ');
      })
      .join('\n');

  Future<T> session<T>(
    Future<T> Function(OfficialHttpSession session) action, {
    void Function()? checkCurrent,
  }) async {
    NativeHttpCookieJar? cookies;
    final generation = _generation;
    void check() {
      if (_disposed || generation != _generation) {
        throw const CommunityException('stale');
      }
      checkCurrent?.call();
    }

    try {
      check();
      cookies = await _cookieLoader().timeout(timeout);
      check();
      return await action(
        OfficialHttpSession._(this, cookies, _fingerprint(cookies), check),
      );
    } on CommunityException {
      rethrow;
    } on FormatException {
      throw const CommunityException('format');
    } on TypeError {
      throw const CommunityException('format');
    } catch (_) {
      throw const CommunityException('network');
    } finally {
      cookies?.clear();
    }
  }

  Future<String> _request(
    OfficialHttpSession session,
    Uri uri, {
    Map<String, String>? form,
    Map<String, String> headers = const {},
  }) async {
    session.checkCurrent();
    final paths = form == null ? _getPaths : _postPaths;
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        paths[uri.host]?.contains(uri.path) != true) {
      throw const CommunityException('endpoint');
    }
    final abort = Completer<void>();
    _requests.add(abort);
    try {
      return await (() async {
        final request = http.AbortableRequest(
          form == null ? 'GET' : 'POST',
          uri,
          abortTrigger: abort.future,
        )..followRedirects = false;
        request.headers.addAll({
          'User-Agent': NativeHttpApi.userAgent,
          'Origin': 'https://ani.gamer.com.tw',
          'Referer': 'https://ani.gamer.com.tw/',
          if (session.cookies.header(uri).isNotEmpty)
            'Cookie': session.cookies.header(uri),
          ...headers,
        });
        if (form != null) request.bodyFields = form;
        // The last check precedes transmission. Never recheck a successful
        // POST acknowledgement and turn it into a retryable failure.
        session.checkCurrent();
        final response = await _client.send(request);
        if (response.statusCode == 401) {
          throw const CommunityException('login');
        }
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers['location'];
          final target = location == null
              ? null
              : uri.resolveUri(Uri.parse(location));
          if (target != null &&
              target.scheme == 'https' &&
              target.host == 'user.gamer.com.tw' &&
              target.port == 443 &&
              target.userInfo.isEmpty &&
              target.path == '/login.php') {
            throw const CommunityException('login');
          }
          throw const CommunityException('unavailable');
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw const CommunityException('unavailable');
        }
        final bytes = <int>[];
        if ((response.contentLength ?? 0) > 2000000) {
          throw const CommunityException('format');
        }
        await for (final chunk in response.stream) {
          if (_disposed) throw const CommunityException('unavailable');
          if (bytes.length + chunk.length > 2000000) {
            throw const CommunityException('format');
          }
          bytes.addAll(chunk);
        }
        final text = utf8.decode(bytes);
        if (text.contains('challenge-platform') ||
            text.contains('cf-chl-') ||
            text.contains('id="challenge-form"')) {
          throw const CommunityException('verification');
        }
        final setCookie = response.headers['set-cookie'];
        if (setCookie != null) session.cookies.receive(uri, setCookie);
        if (form == null) session.checkCurrent();
        return text;
      })().timeout(timeout);
    } finally {
      if (!abort.isCompleted) abort.complete();
      _requests.remove(abort);
    }
  }

  /// Invalidates reads and writes before a login/logout or account change.
  void invalidate() {
    _generation++;
    for (final abort in _requests) {
      if (!abort.isCompleted) abort.complete();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    invalidate();
    _client.close();
  }
}

class OfficialHttpSession {
  OfficialHttpSession._(
    this._client,
    this.cookies,
    this._fingerprint,
    this.checkCurrent,
  );
  final OfficialHttpClient _client;
  final NativeHttpCookieJar cookies;
  final String _fingerprint;
  final void Function() checkCurrent;

  Future<String> get(Uri uri) => _client._request(this, uri);
  Future<Json> json(Uri uri) async => jsonDecode(await get(uri)) as Json;

  Future<void> revalidate() async {
    checkCurrent();
    final current = await _client._cookieLoader().timeout(_client.timeout);
    try {
      checkCurrent();
      if (OfficialHttpClient._fingerprint(current) != _fingerprint) {
        throw const CommunityException('stale');
      }
    } finally {
      current.clear();
    }
  }

  /// Mirrors Bahamut.Csrf: a random token in both a parent-domain cookie and
  /// header. This cookie lives only in the request session.
  Map<String, String> csrfHeaders() {
    final random = Random.secure();
    final token = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    cookies.receive(
      Uri.https('ani.gamer.com.tw', '/'),
      'ckBahamutCsrfToken=$token; Domain=gamer.com.tw; Path=/; Secure',
    );
    return {'X-Bahamut-Csrf-Token': token};
  }

  Future<String> post(
    Uri uri,
    Map<String, String> form, {
    Map<String, String> headers = const {},
  }) async {
    await revalidate();
    return _client._request(this, uri, form: form, headers: headers);
  }
}
