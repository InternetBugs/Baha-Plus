import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/community.dart';
import '../core/models.dart';
import '../core/native_danmaku.dart';
import 'http_pool.dart';
import 'native_http_api.dart';
import 'official_account_profile.dart';
import 'official_http_client.dart';
import 'official_user_agent.dart';

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
  static final _videoId = RegExp(r'^[1-9][0-9]{0,9}$');
  static final _color = RegExp(r'^#[0-9a-fA-F]{6}$');
  static final _invalidToken = RegExp(r'[<>\r\n]');
  static final _danmakuId = RegExp(r'^[1-9][0-9]{0,19}$');
  final http.Client _client;
  final Future<NativeHttpCookieJar> Function() _cookieLoader;
  final Duration timeout;
  final _requests = <Completer<void>>{};
  bool _disposed = false, _sending = false;

  static Future<NativeHttpCookieJar> _officialCookies() =>
      OfficialHttpClient.loadCookies(urls: [_account, _token, _send]);

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
    if (!_videoId.hasMatch(videoId) ||
        !DanmakuSettings.validMessage(text) ||
        !_color.hasMatch(color) ||
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
      final urls = [_account, _token, _send];
      final fingerprint = cookies.fingerprint(urls);
      final preflight = await Future.wait([
        _request(_account, cookies, videoId, checkCurrent),
        _request(_token, cookies, videoId, checkCurrent),
      ]);
      final page = await parseOfficialHtml(preflight.first);
      final actualOwner = parseOfficialAccountProfile(page)?.id;
      if (actualOwner == null) {
        throw const CommunityException('login');
      }
      if (actualOwner.toLowerCase() != owner.toLowerCase()) {
        throw const CommunityException('stale');
      }
      checkCurrent();
      final token = preflight.last.trim();
      if (token.isEmpty ||
          token.length > 500 ||
          token.contains(_invalidToken)) {
        throw const CommunityException('unavailable');
      }
      // A logout or account switch while awaiting CSRF must never post using
      // an earlier account's cookies, even if its display cache is unchanged.
      final currentCookies = await _cookieLoader().timeout(timeout);
      try {
        if (fingerprint != currentCookies.fingerprint(urls)) {
          throw const CommunityException('stale');
        }
        cookies.adoptDeviceRotation(currentCookies);
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
          checkCurrent,
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
          !_danmakuId.hasMatch('$id')) {
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
    String videoId,
    void Function() checkCurrent, {
    Map<String, String>? form,
  }) async {
    if (_disposed) throw const CommunityException('unavailable');
    await OfficialUserAgent.ensureResolved();
    checkCurrent();
    if (_disposed) throw const CommunityException('unavailable');
    final abort = Completer<void>();
    _requests.add(abort);
    String? responseCookies;
    final sentHeader = cookies.header(uri);
    try {
      final body = await (() async {
        final request = http.AbortableRequest(
          form == null ? 'GET' : 'POST',
          uri,
          abortTrigger: abort.future,
        )..followRedirects = false;
        request.headers.addAll({
          'User-Agent': OfficialUserAgent.value,
          'Origin': 'https://ani.gamer.com.tw',
          'Referer': Uri.https('ani.gamer.com.tw', '/animeVideo.php', {
            'sn': videoId,
          }).toString(),
          'Cookie': sentHeader,
        });
        if (form != null) request.bodyFields = form;
        final response = await _client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await cancelResponse(response);
          throw CommunityException(
            response.statusCode == 401 ? 'login' : 'unavailable',
          );
        }
        final bytes = BytesBuilder(copy: false);
        if ((response.contentLength ?? 0) > 1000000) {
          await cancelResponse(response);
          throw const CommunityException('format');
        }
        await for (final chunk in response.stream) {
          if (_disposed) throw const CommunityException('unavailable');
          if (bytes.length + chunk.length > 1000000) {
            throw const CommunityException('format');
          }
          bytes.add(chunk);
        }
        final text = utf8.decode(bytes.takeBytes());
        if (text.contains('challenge-platform') || text.contains('cf-chl-')) {
          throw const CommunityException('unavailable');
        }
        responseCookies = response.headers['set-cookie'];
        return text;
      })().timeout(timeout);
      if (responseCookies != null) {
        await cookies.receiveResponse(uri, responseCookies!, sentHeader, () {
          checkCurrent();
          return !_disposed;
        });
      }
      return body;
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
