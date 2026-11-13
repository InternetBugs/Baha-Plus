import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;

import '../core/community.dart';
import '../core/models.dart';
import '../core/native_danmaku.dart';
import 'native_http_api.dart';
import 'official_account_profile.dart';

/// An explicit account write with its own short-lived account HTTP client.
/// Cookies are read through the native plugin, without mounting a WebView.
class NativeDanmakuSender {
  NativeDanmakuSender({
    http.Client? client,
    Future<NativeHttpCookieJar> Function()? cookieLoader,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client(),
       _cookieLoader = cookieLoader ?? _officialCookies;

  static final _account = Uri.https('ani.gamer.com.tw', '/mygather.php');
  static final _token = Uri.https('ani.gamer.com.tw', '/ajax/getCSRFToken.php');
  static final _send = Uri.https('ani.gamer.com.tw', '/ajax/danmuSet.php');
  static final _owner = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  final http.Client _client;
  final Future<NativeHttpCookieJar> Function() _cookieLoader;
  final Duration timeout;
  final _requests = <Completer<void>>{};
  bool _disposed = false, _sending = false;

  static Future<NativeHttpCookieJar> _officialCookies() async {
    final jar = NativeHttpCookieJar();
    final manager = CookieManager.instance();
    for (final uri in [_account, _token, _send]) {
      final cookies = await manager.getCookies(url: WebUri(uri.toString()));
      for (final cookie in cookies) {
        final name = cookie.name, value = '${cookie.value}';
        if (!RegExp(r'^[!#$%&*+\-.^_`|~0-9A-Za-z]+$').hasMatch(name) ||
            value.contains(RegExp(r'[\x00-\x20\x7f";,\\]'))) {
          continue;
        }
        final path = cookie.path ?? '/';
        final domain = cookie.domain;
        if (!path.startsWith('/') || path.contains(RegExp(r'[;\r\n]'))) {
          continue;
        }
        if (domain != null &&
            !const [
              'gamer.com.tw',
              'ani.gamer.com.tw',
            ].contains(domain.replaceFirst(RegExp(r'^\.'), '').toLowerCase())) {
          continue;
        }
        final expiry = cookie.expiresDate;
        if (expiry != null && expiry <= DateTime.now().millisecondsSinceEpoch) {
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

  static String _fingerprint(NativeHttpCookieJar jar) =>
      [_account, _token, _send]
          .map((uri) {
            final values = jar.header(uri).split('; ')..sort();
            return values.join('; ');
          })
          .join('\n');

  Future<NativeDanmaku> send({
    required String videoId,
    required String owner,
    required String text,
    required String color,
    required int position,
    required int size,
    required void Function() checkCurrent,
    required double Function() currentPosition,
  }) async {
    if (_disposed) throw const CommunityException('unavailable');
    if (_sending) throw const CommunityException('busy');
    if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(videoId) ||
        !DanmakuSettings.validMessage(text) ||
        !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color) ||
        !const [0, 1, 2].contains(position) ||
        !const [0, 1, 2].contains(size)) {
      throw const CommunityException('input');
    }
    if (!_owner.hasMatch(owner) || owner.toLowerCase() == 'guest') {
      throw const CommunityException('login');
    }
    _sending = true;
    NativeHttpCookieJar? cookies;
    try {
      checkCurrent();
      cookies = await _cookieLoader().timeout(timeout);
      checkCurrent();
      if (cookies.header(_account).isEmpty) {
        throw const CommunityException('login');
      }
      final fingerprint = _fingerprint(cookies);
      final page = parse(await _request(_account, cookies, videoId));
      final actualOwner = officialAccountProfile(page)?['id'] as String?;
      if (actualOwner == null) {
        throw const CommunityException('login');
      }
      if (actualOwner.toLowerCase() != owner.toLowerCase()) {
        throw const CommunityException('stale');
      }
      checkCurrent();
      final token = (await _request(_token, cookies, videoId)).trim();
      if (token.isEmpty ||
          token.length > 500 ||
          token.contains(RegExp(r'[<>\r\n]'))) {
        throw const CommunityException('unavailable');
      }
      // A logout or account switch while awaiting CSRF must never post using
      // an earlier account's cookies, even if its display cache is unchanged.
      final currentCookies = await _cookieLoader().timeout(timeout);
      try {
        if (fingerprint != _fingerprint(currentCookies)) {
          throw const CommunityException('stale');
        }
      } finally {
        currentCookies.clear();
      }
      checkCurrent();
      final seconds = currentPosition();
      if (!seconds.isFinite || seconds < 0 || seconds > 172800) {
        throw const CommunityException('input');
      }
      final time = (seconds * 10).floor();
      final response = jsonDecode(
        await _request(
          _send,
          cookies,
          videoId,
          form: {
            'sn': videoId,
            'content': text.trim(),
            'color': color,
            'position': '$position',
            'size': '$size',
            'time': '$time',
            'token': token,
          },
        ),
      );
      if (response is! Json) throw const CommunityException('format');
      if (response['nologin'] != null &&
          response['nologin'] != false &&
          response['nologin'] != 0) {
        throw const CommunityException('login');
      }
      final id = response['sn'];
      if ((response['error'] != null &&
              response['error'] != false &&
              response['error'] != 0) ||
          (id is! int && id is! String) ||
          !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch('$id')) {
        throw const CommunityException('rejected');
      }
      // Do not recheck navigation after acknowledgement or turn a successful
      // write into a failure the user might retry. The store gates display.
      return NativeDanmaku.fromJson({
        'id': '$id',
        'text': text.trim(),
        'time': time / 10,
        'color': color,
        'mode': ['rolling', 'top', 'bottom'][position],
        'size': [16, 24, 28][size],
      });
    } on CommunityException {
      rethrow;
    } on FormatException {
      throw const CommunityException('format');
    } catch (_) {
      throw const CommunityException('network');
    } finally {
      cookies?.clear();
      _sending = false;
    }
  }

  Future<String> _request(
    Uri uri,
    NativeHttpCookieJar cookies,
    String videoId, {
    Map<String, String>? form,
  }) async {
    if (_disposed) throw const CommunityException('unavailable');
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
          'Referer': Uri.https('ani.gamer.com.tw', '/animeVideo.php', {
            'sn': videoId,
          }).toString(),
          'Cookie': cookies.header(uri),
        });
        if (form != null) request.bodyFields = form;
        final response = await _client.send(request);
        if (response.statusCode == 401) throw const CommunityException('login');
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw const CommunityException('unavailable');
        }
        final setCookie = response.headers['set-cookie'];
        if (setCookie != null) cookies.receive(uri, setCookie);
        final bytes = <int>[];
        if ((response.contentLength ?? 0) > 1000000) {
          throw const CommunityException('format');
        }
        await for (final chunk in response.stream) {
          if (_disposed) throw const CommunityException('unavailable');
          if (bytes.length + chunk.length > 1000000) {
            throw const CommunityException('format');
          }
          bytes.addAll(chunk);
        }
        final text = utf8.decode(bytes);
        if (text.contains('challenge-platform') || text.contains('cf-chl-')) {
          throw const CommunityException('unavailable');
        }
        return text;
      })().timeout(timeout);
    } finally {
      if (!abort.isCompleted) abort.complete();
      _requests.remove(abort);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final abort in _requests) {
      if (!abort.isCompleted) abort.complete();
    }
    _client.close();
  }
}
