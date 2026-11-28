import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../core/community.dart';
import '../core/models.dart';
import 'http_pool.dart';
import 'native_http_api.dart';
import 'official_cookie_rotation.dart';
import 'official_user_agent.dart';

/// Account HTTP operations import the device's official cookies into memory.
/// Neither a browser document nor JavaScript is needed. Playback imports a
/// separate snapshot and never shares this client's mutable session.
class OfficialHttpClient {
  OfficialHttpClient({
    http.Client? client,
    http.Client Function()? clientFactory,
    Future<NativeHttpCookieJar> Function()? cookieLoader,
    Future<void> Function()? cookieClearer,
    this.timeout = const Duration(seconds: 12),
  }) : _pool = RetryingHttpClientPool(
         client: client,
         clientFactory: clientFactory,
       ),
       _cookieLoader = cookieLoader ?? loadCookies,
       _cookieClearer = cookieClearer ?? clearDeviceCookies;

  static const hosts = {
    'ani.gamer.com.tw',
    'api.gamer.com.tw',
    'wall.gamer.com.tw',
    'user.gamer.com.tw',
  };
  static final _cookieURLs = [
    Uri.https('ani.gamer.com.tw', '/mygather.php'),
    Uri.https('ani.gamer.com.tw', '/ajax/getCSRFToken.php'),
    Uri.https('api.gamer.com.tw', '/anime/v3/history.php'),
    Uri.https('wall.gamer.com.tw', '/app/v1/comment_new.php'),
    OfficialSite.logout,
  ];
  static const _getPaths = {
    'ani.gamer.com.tw': {
      '/mygather.php',
      '/search.php',
      '/animeVideo.php',
      '/ajax/getCSRFToken.php',
    },
    'api.gamer.com.tw': {'/anime/v3/history.php', '/ajax/common/topBar.php'},
    // Public profile reads carry no cookies: this host is excluded from hosts.
    'home.gamer.com.tw': {'/profile/index.php'},
    'wall.gamer.com.tw': {
      '/app/v2/comment_detail.php',
      '/app/v1/reply_detail.php',
    },
    'user.gamer.com.tw': {'/logout.php'},
  };
  static const _postPaths = {
    'ani.gamer.com.tw': {'/ajax/want2play.php', '/ajax/delgather.php'},
    'user.gamer.com.tw': {'/logout.php'},
    'wall.gamer.com.tw': {
      '/app/v1/comment_new.php',
      '/app/v1/comment_like.php',
      '/app/v1/comment_like_del.php',
    },
  };
  static final _domainPrefix = RegExp(r'^\.');
  static final _cookieName = RegExp(r'^[!#$%&*+\-.^_`|~0-9A-Za-z]+$');
  static final _invalidCookieValue = RegExp(r'[\x00-\x20\x7f";,\\]');
  static final _invalidCookiePath = RegExp(r'[;\r\n]');
  final RetryingHttpClientPool _pool;
  final Future<NativeHttpCookieJar> Function() _cookieLoader;
  final Future<void> Function() _cookieClearer;
  final Duration timeout;
  int _generation = 0;
  bool _disposed = false;

  static Future<NativeHttpCookieJar> loadPlaybackCookies() =>
      loadCookies(urls: NativeHttpApi.cookieURLs);

  static Future<void> clearDeviceCookies() async {
    // Android also returns false when the store already contains no cookies.
    await CookieManager.instance().deleteAllCookies();
    final remaining = await loadCookies();
    try {
      if (_cookieURLs.any((uri) => remaining.header(uri).isNotEmpty)) {
        throw const CommunityException('unavailable');
      }
    } finally {
      remaining.clear();
    }
  }

  Future<void> clearCookies() async {
    invalidate();
    await OfficialCookieRotation.clear(_cookieClearer).timeout(timeout);
  }

  static Future<NativeHttpCookieJar> loadCookies({List<Uri>? urls}) async {
    final jar = NativeHttpCookieJar(
      allowedHosts: hosts,
      persistLoginRotation: true,
    );
    final manager = OfficialCookieRotation.manager;
    final now = DateTime.now().millisecondsSinceEpoch;
    // WebView2 returns CDP expiry in seconds and -1 for session cookies.
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final batches = await Future.wait([
      for (final uri in urls ?? _cookieURLs)
        manager
            .getCookies(url: WebUri(uri.toString()))
            .then((cookies) => (uri, cookies)),
    ]);
    for (final (uri, cookies) in batches) {
      for (final cookie in cookies) {
        final name = cookie.name, value = '${cookie.value}';
        final path = cookie.path ?? '/';
        final domain = cookie.domain
            ?.replaceFirst(_domainPrefix, '')
            .toLowerCase();
        final expires = cookie.expiresDate;
        if (!_cookieName.hasMatch(name) ||
            value.contains(_invalidCookieValue) ||
            !path.startsWith('/') ||
            path.contains(_invalidCookiePath) ||
            (domain != null &&
                domain != 'gamer.com.tw' &&
                domain != uri.host) ||
            (expires != null &&
                cookie.isSessionOnly != true &&
                expires <= (windows ? now ~/ 1000 : now))) {
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

  Future<T> session<T>(
    Future<T> Function(OfficialHttpSession session) action, {
    void Function()? checkCurrent,
  }) async {
    NativeHttpCookieJar? cookies;
    final generation = _generation;
    final ended = Completer<void>();
    void check() {
      if (ended.isCompleted || _disposed || generation != _generation) {
        throw const CommunityException('stale');
      }
      checkCurrent?.call();
    }

    try {
      check();
      cookies = await _cookieLoader().timeout(timeout);
      check();
      return await action(
        OfficialHttpSession._(
          this,
          cookies,
          cookies.fingerprint(_cookieURLs, ignoreCsrf: true),
          check,
          ended.future,
        ),
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
      ended.complete();
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
    try {
      final (body, responseCookies, sentHeader) = await _pool.run(
        (client, abort, attempt) async {
          await OfficialUserAgent.ensureResolved();
          session.checkCurrent();
          final sentHeader = session.cookies.header(uri);
          final request =
              http.AbortableRequest(
                  form == null ? 'GET' : 'POST',
                  uri,
                  abortTrigger: abort,
                )
                ..followRedirects = false
                ..persistentConnection = attempt == 0;
          request.headers.addAll({
            'User-Agent': OfficialUserAgent.value,
            'Origin': uri == OfficialSite.logout
                ? OfficialSite.logout.origin
                : 'https://ani.gamer.com.tw',
            'Referer': uri == OfficialSite.logout
                ? OfficialSite.logout.toString()
                : 'https://ani.gamer.com.tw/',
            if (sentHeader.isNotEmpty) 'Cookie': sentHeader,
            ...headers,
          });
          if (form != null) request.bodyFields = form;
          // The last check precedes transmission. Never recheck a successful
          // POST acknowledgement and turn it into a retryable failure.
          session.checkCurrent();
          final response = await client.send(request);
          if (response.statusCode == 401) {
            await cancelResponse(response);
            throw const CommunityException('login');
          }
          if (response.statusCode >= 300 && response.statusCode < 400) {
            await cancelResponse(response);
            final location = response.headers['location'];
            final target = location == null
                ? null
                : uri.resolveUri(Uri.parse(location));
            final logout = uri == OfficialSite.logout;
            if (!logout &&
                target != null &&
                target.scheme == 'https' &&
                target.host == 'user.gamer.com.tw' &&
                target.port == 443 &&
                target.userInfo.isEmpty &&
                target.path == '/login.php') {
              throw const CommunityException('login');
            }
            // Logout normally redirects to a public Bahamut page. Acknowledge
            // that response without forwarding credentials or loading a page.
            if (logout &&
                const [301, 302, 303, 307, 308].contains(response.statusCode) &&
                target != null &&
                OfficialSite.allowedNavigation(target) &&
                target.port == 443 &&
                target.userInfo.isEmpty) {
              return ('', null, sentHeader);
            }
            throw const CommunityException('unavailable');
          }
          if (response.statusCode < 200 || response.statusCode >= 300) {
            await cancelResponse(response);
            throw const CommunityException('unavailable');
          }
          final bytes = BytesBuilder(copy: false);
          if ((response.contentLength ?? 0) > 2000000) {
            await cancelResponse(response);
            throw const CommunityException('format');
          }
          await for (final chunk in response.stream) {
            if (_disposed) throw const CommunityException('unavailable');
            if (bytes.length + chunk.length > 2000000) {
              throw const CommunityException('format');
            }
            bytes.add(chunk);
          }
          final text = utf8.decode(bytes.takeBytes());
          if (text.contains('challenge-platform') ||
              text.contains('cf-chl-') ||
              text.contains('id="challenge-form"')) {
            throw const CommunityException('verification');
          }
          return (text, response.headers['set-cookie'], sentHeader);
        },
        timeout: timeout,
        maxRetries: form == null ? 1 : 0,
        cancel: session._ended,
        retryAfter: (error, _) => RetryingHttpClientPool.isTransportError(error)
            ? Duration.zero
            : null,
      );
      if (responseCookies != null) {
        await session.cookies.receiveResponse(
          uri,
          responseCookies,
          sentHeader,
          () {
            session.checkCurrent();
            return uri != OfficialSite.logout;
          },
        );
      }
      if (form == null) session.checkCurrent();
      return body;
    } on HttpPoolCancelled {
      session.checkCurrent();
      throw const CommunityException('stale');
    }
  }

  /// Invalidates reads and writes before a login/logout or account change.
  void invalidate() {
    OfficialCookieRotation.invalidate();
    _generation++;
    _pool.abortAll();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    invalidate();
    _pool.dispose();
  }
}

class OfficialHttpSession {
  OfficialHttpSession._(
    this._client,
    this.cookies,
    this._fingerprint,
    this.checkCurrent,
    this._ended,
  );
  final OfficialHttpClient _client;
  final NativeHttpCookieJar cookies;
  final String _fingerprint;
  final void Function() checkCurrent;
  final Future<void> _ended;

  Future<String> get(Uri uri) => _client._request(this, uri);
  Future<Json> json(Uri uri) async => jsonDecode(await get(uri)) as Json;

  Future<void> revalidate() async {
    checkCurrent();
    final current = await _client._cookieLoader().timeout(_client.timeout);
    try {
      checkCurrent();
      if (current.fingerprint(
            OfficialHttpClient._cookieURLs,
            ignoreCsrf: true,
          ) !=
          _fingerprint) {
        throw const CommunityException('stale');
      }
      cookies.adoptDeviceRotation(current);
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
