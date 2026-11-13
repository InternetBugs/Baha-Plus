import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parseFragment;

import '../core/models.dart';
import '../core/native_danmaku.dart';
import 'native_playback.dart';

class NativeHttpException implements Exception {
  const NativeHttpException(this.stage, [this.code]);
  final String stage;
  final int? code;

  // Transport errors and response bodies may contain session credentials.
  @override
  String toString() => 'NativeHttpException($stage, $code)';
}

class NativeHttpAd {
  const NativeHttpAd(this.id, this.sid);
  final String id, sid;
  Uri get playlist =>
      Uri.https('bahamut.akamaized.net', '/ad/$id/playlist.m3u8');
}

class NativeHttpPreparation {
  const NativeHttpPreparation({
    required this.title,
    required this.rating,
    required this.position,
    required this.duration,
    required this.ad,
  });
  final String title;
  final int rating;
  final double position, duration;
  final NativeHttpAd? ad;
}

/// Closed-origin, in-memory guest cookies. Never imports browser/account data.
class NativeHttpCookieJar {
  final _cookies =
      <String, ({Cookie cookie, bool hostOnly, DateTime? until})>{};

  static bool _trusted(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      const ['ani.gamer.com.tw', 'api.gamer.com.tw'].contains(uri.host);

  void receive(Uri uri, String raw, {DateTime? now}) {
    if (!_trusted(uri)) return;
    final time = now ?? DateTime.now().toUtc();
    // package:http joins repeated headers. Do not split the comma in Expires.
    for (final item in raw.split(RegExp(r',(?=\s*[^;,\s=]+=)'))) {
      try {
        final cookie = Cookie.fromSetCookieValue(item.trim());
        final hostOnly = cookie.domain == null;
        final domain = (cookie.domain ?? uri.host)
            .replaceFirst(RegExp(r'^\.'), '')
            .toLowerCase();
        if (domain != uri.host && domain != 'gamer.com.tw') continue;
        if (cookie.value.contains(RegExp(r'[\x00-\x20\x7f";,\\]'))) continue;
        cookie.domain = domain;
        final path = cookie.path;
        if (path == null || !path.startsWith('/')) {
          final slash = uri.path.lastIndexOf('/');
          cookie.path = slash <= 0 ? '/' : uri.path.substring(0, slash);
        }
        final key = '${cookie.name}\n$domain\n${cookie.path}';
        final until = cookie.maxAge == null
            ? cookie.expires
            : time.add(Duration(seconds: cookie.maxAge!));
        _cookies.remove(key);
        if (until == null || until.isAfter(time)) {
          _cookies[key] = (cookie: cookie, hostOnly: hostOnly, until: until);
        }
      } on FormatException {
        // Ignore a malformed cookie without exposing its value.
      }
    }
  }

  String header(Uri uri, {DateTime? now}) {
    if (!_trusted(uri)) return '';
    final time = now ?? DateTime.now().toUtc();
    _cookies.removeWhere(
      (_, entry) => entry.until != null && !entry.until!.isAfter(time),
    );
    final matching =
        _cookies.values.where((entry) {
          final cookie = entry.cookie;
          final domain = cookie.domain!;
          final path = cookie.path!;
          final requestPath = uri.path.isEmpty ? '/' : uri.path;
          return (uri.host == domain ||
                  (!entry.hostOnly && uri.host.endsWith('.$domain'))) &&
              (requestPath == path ||
                  (requestPath.startsWith(path) &&
                      (path.endsWith('/') ||
                          requestPath.substring(path.length).startsWith('/'))));
        }).toList()..sort(
          (a, b) => b.cookie.path!.length.compareTo(a.cookie.path!.length),
        );
    return matching
        .map((entry) => '${entry.cookie.name}=${entry.cookie.value}')
        .join('; ');
  }

  void clear() => _cookies.clear();
}

/// Port of the Android TV nativeApi experiment's official web HTTP protocol.
/// Each episode owns an isolated guest session, including ads and device IDs.
class NativeHttpApi {
  NativeHttpApi({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.onEvent,
  }) : _client = client ?? http.Client();

  static const userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  final http.Client _client;
  final Duration timeout;
  final void Function(String stage, int? code)? onEvent;
  final _cookies = NativeHttpCookieJar();
  final _requests = <Completer<void>>{};
  bool _disposed = false, _consented = false, _adStarted = false;
  bool _adEnded = false;
  String _device = '', _video = '';
  NativeHttpPreparation? _preparation;

  Future<NativeHttpPreparation> prepare(String videoId) async {
    if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(videoId) || _video.isNotEmpty) {
      throw const NativeHttpException('video-id');
    }
    _video = videoId;
    await _text('page', _web('/animeVideo.php', {'sn': _video}));
    _device = _deviceId(
      (await _json('device', _web('/ajax/getdeviceid.php')))['deviceid'],
    );
    final metadata = await _json(
      'metadata',
      _api('/anime/v1/video.php', {'videoSn': _video}),
    );
    final video = (metadata['data'] as Json)['video'] as Json;
    if (video['requestParentPassword'] == true) {
      throw const NativeHttpException('parent-verification-required');
    }
    final random = Random.secure();
    final policy = await _json(
      'policy',
      _web('/ajax/token.php', {
        'adID': 'undefined',
        'sn': _video,
        'device': _device,
        'hash': List.generate(
          6,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
      }),
    );
    if (policy['time'] is! num) {
      throw const NativeHttpException('policy-format');
    }
    NativeHttpAd? ad;
    if (policy['time'] != 1) {
      final ads = parseAds(
        await _text(
          'ad-config',
          Uri.https('i2.bahamut.com.tw', '/JS/ad/animeVideo.js'),
        ),
      );
      ad = ads[random.nextInt(ads.length)];
    }
    double number(dynamic raw) =>
        raw is num && raw.isFinite && raw >= 0 ? raw.toDouble() : 0;
    final breakpoint = video['breakpoint'];
    return _preparation = NativeHttpPreparation(
      title: video['title'] as String,
      rating: (policy['r18'] as num? ?? video['rating'] as num? ?? 1).toInt(),
      position: number(breakpoint is Json ? breakpoint['breakPoint'] : null),
      duration: number(video['duration']),
      ad: ad,
    );
  }

  void consent() {
    if (_preparation == null || _disposed) {
      throw const NativeHttpException('consent-state');
    }
    _consented = true;
  }

  Future<void> startAd() async {
    final ad = _preparation?.ad;
    if (!_consented || ad == null || _adStarted) {
      throw const NativeHttpException('ad-start-state');
    }
    await _event('ad-start', '/ajax/videoCastcishu.php', {
      's': ad.sid,
      'sn': _video,
    });
    _adStarted = true;
  }

  Future<void> endAd(double actualSeconds) async {
    final ad = _preparation?.ad;
    if (!_adStarted ||
        ad == null ||
        _adEnded ||
        !actualSeconds.isFinite ||
        actualSeconds < 30) {
      throw const NativeHttpException('ad-incomplete');
    }
    await _event('ad-end', '/ajax/videoCastcishu.php', {
      's': ad.sid,
      'sn': _video,
      'ad': 'end',
    });
    _adEnded = true;
  }

  Future<NativePlaybackSource> source({
    double? position,
    bool paused = false,
    double rate = 1,
    bool muted = false,
  }) async {
    final preparation = _preparation;
    if (preparation == null ||
        !_consented ||
        (preparation.ad != null && !_adEnded)) {
      throw const NativeHttpException('source-gated');
    }
    final response = await _json(
      'source',
      _api('/anime/v1/video_src.php', {
        'videoSn': _video,
        'deviceid': _device,
        'deviceTypeUseCases': '1',
      }),
    );
    final data = response['data'] as Json;
    _device = _deviceId(data['deviceid']);
    final cases = data['srcUseCases'] as List;
    final selected = cases.cast<Json>().where(
      (item) => item['deviceType'] == 1,
    );
    if (selected.isEmpty) throw const NativeHttpException('source-type');
    final master = NativePlaybackSource.mediaUri(
      (selected.first['src'] as Json)['playlist'],
    );
    final playlist = await _text('playlist', master);
    final variants = parseVariants(master, playlist);
    // Catalog duration is not a media clock. Use HLS seconds for resume bounds.
    final media = variants.isEmpty
        ? playlist
        : await _text('media-playlist', variants.values.first);
    final duration = RegExp(r'#EXTINF:([0-9.]+)')
        .allMatches(media)
        .fold<double>(0, (sum, match) => sum + double.parse(match[1]!));
    if (!duration.isFinite || duration <= 0 || duration > 172800) {
      throw const NativeHttpException('media-duration');
    }
    return NativePlaybackSource.fromJson({
      'master': master.toString(),
      'variants': [
        for (final entry in variants.entries)
          {'height': entry.key, 'url': entry.value.toString()},
      ],
      'position': (position ?? preparation.position).clamp(0.0, duration),
      'duration': duration,
      'paused': paused,
      'rate': rate,
      'muted': muted,
    });
  }

  Future<void> started() async {
    await _event('device-lock', '/ajax/checklock.php', {
      'sn': _video,
      'device': _device,
    });
    await _event('video-start', '/ajax/checklock.php', {'sn': _video});
  }

  Future<List<NativeDanmaku>> danmaku() async {
    if (_preparation == null ||
        !_consented ||
        (_preparation!.ad != null && !_adEnded)) {
      throw const NativeHttpException('danmaku-gated');
    }
    return parseDanmaku(
      await _json(
        'danmaku',
        _api('/anime/v1/danmu.php', {'videoSn': _video, 'geo': 'TW,HK'}),
      ),
    );
  }

  /// Official API units differ from the already formatted WebView bridge:
  /// time is in tenths of a second, size/position are enum values, text is HTML.
  static List<NativeDanmaku> parseDanmaku(Json response) {
    final data = response['data'];
    final rows = data is Json ? data['danmu'] : null;
    if (rows is! List || rows.length > 20000) {
      throw const NativeHttpException('danmaku-format');
    }
    final items = <String, NativeDanmaku>{};
    for (final row in rows) {
      if (row is! Json) continue;
      final id = row['sn'];
      final time = row['time'];
      final rawText = row['text'];
      if ((id is! int && id is! String) ||
          !RegExp(r'^\d{1,20}$').hasMatch('$id') ||
          items.containsKey('$id') ||
          time is! num ||
          !time.isFinite ||
          time < 0 ||
          time > 1728000 ||
          rawText is! String ||
          rawText.length > 10000) {
        continue;
      }
      final text = (parseFragment(rawText).text ?? '')
          .replaceAll(RegExp(r'[\s\u00a0]+'), ' ')
          .trim();
      if (text.isEmpty || text.length > 500) continue;
      final color = row['color'];
      items['$id'] = NativeDanmaku.fromJson({
        'id': '$id',
        'time': time / 10,
        'text': text,
        'mode': switch (row['position']) {
          1 => 'top',
          2 => 'bottom',
          _ => 'rolling',
        },
        'size': switch (row['size']) {
          0 => 16,
          2 => 28,
          _ => 24,
        },
        'color': color is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)
            ? color
            : '#FFFFFF',
      });
    }
    final sorted = items.values.toList()
      ..sort((a, b) {
        final time = a.time.compareTo(b.time);
        if (time != 0) return time;
        final length = a.id.length.compareTo(b.id.length);
        return length != 0 ? length : a.id.compareTo(b.id);
      });
    return List.unmodifiable(sorted);
  }

  Future<void> state(double actualSeconds) => _event(
    'playback-state',
    '/ajax/unlock.php',
    {'sn': _video, 'ttl': actualSeconds.floor().toString()},
  );

  Future<bool> progress(double position, double duration) async {
    final result = await _json(
      'progress',
      _web('/ajax/elapse.php', {
        'sn': _video,
        'device': _device,
        'time': progressParameter(position, duration).toString(),
      }),
    );
    if (result['state'] == 'ok') {
      if (result['device'] != null && result['device'] != '') {
        _device = _deviceId(result['device']);
      }
      return true;
    }
    if (result['state'].toString() == '1') return false;
    throw NativeHttpException(
      'progress-denied',
      int.tryParse('${result['state']}'),
    );
  }

  static int progressParameter(double position, double duration) {
    if (!position.isFinite ||
        !duration.isFinite ||
        position < 0 ||
        duration <= 0 ||
        position > duration + 1) {
      throw const NativeHttpException('progress-timeline');
    }
    return (duration - position).abs() <= 120 ? -1 : position.round();
  }

  static List<NativeHttpAd> parseAds(String script) {
    final block = RegExp(
      r'function\s*\([^)]*\)\s*\{.*?var\s+adlist\s*=\s*(\[\[.*?]]);',
      dotAll: true,
    ).firstMatch(script)?[1];
    if (block == null) throw const NativeHttpException('ad-config-format');
    final list = jsonDecode(block) as List;
    final result = <NativeHttpAd>[];
    final id = RegExp(r'^[0-9]{1,20}$');
    for (final row in list) {
      if (row is! List || row.length < 4 || row[3] != 'video') continue;
      if (id.hasMatch('${row[0]}') && id.hasMatch('${row[2]}')) {
        result.add(NativeHttpAd('${row[0]}', '${row[2]}'));
      }
    }
    if (result.isEmpty) throw const NativeHttpException('ad-config-empty');
    return result;
  }

  static Map<int, Uri> parseVariants(Uri master, String playlist) {
    if (!playlist.trimLeft().startsWith('#EXTM3U')) {
      throw const NativeHttpException('playlist-format');
    }
    final result = <int, Uri>{};
    int? height;
    for (final line in const LineSplitter().convert(playlist)) {
      final value = line.trim();
      if (value.startsWith('#EXT-X-STREAM-INF:')) {
        height = int.tryParse(
          RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(value)?[1] ?? '',
        );
      } else if (value.isNotEmpty && !value.startsWith('#') && height != null) {
        if (height < 144 || height > 4320 || result.length >= 20) {
          throw const NativeHttpException('playlist-variants');
        }
        final uri = NativePlaybackSource.mediaUri(
          master.resolve(value).toString(),
        );
        result[height] = uri;
        height = null;
      }
    }
    return result;
  }

  String _deviceId(dynamic raw) {
    if (raw is! String ||
        raw.isEmpty ||
        raw.length > 1024 ||
        raw.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      throw const NativeHttpException('device-format');
    }
    return raw;
  }

  Uri _web(String path, [Map<String, String>? query]) =>
      Uri.https('ani.gamer.com.tw', path, query);
  Uri _api(String path, Map<String, String> query) =>
      Uri.https('api.gamer.com.tw', path, query);

  Future<Json> _json(String stage, Uri uri) async {
    final text = await _text(stage, uri);
    try {
      final body = jsonDecode(text) as Json;
      _checkError(stage, body);
      return body;
    } on NativeHttpException {
      rethrow;
    } catch (_) {
      throw NativeHttpException('$stage-format');
    }
  }

  void _checkError(String stage, Json body) {
    final error = body['error'];
    if (error != null && error != false && error != 0) {
      throw NativeHttpException(
        stage,
        error is Json && error['code'] is int
            ? error['code'] as int
            : error is int
            ? error
            : null,
      );
    }
  }

  Future<void> _event(
    String stage,
    String path,
    Map<String, String> query,
  ) async {
    final text = (await _text(stage, _web(path, query))).trim();
    if (text.startsWith('{')) {
      try {
        final body = jsonDecode(text) as Json;
        // These are notifications: the official player only awaits fetch().
        // Its numeric `error` fields are not the policy/source error schema.
        // Keep explicit structured errors, matching the TV experiment.
        if (body['error'] is Json) _checkError(stage, body);
      } on NativeHttpException {
        rethrow;
      } catch (_) {
        throw NativeHttpException('$stage-format');
      }
    }
  }

  Future<String> _text(String stage, Uri uri) async {
    if (_disposed) throw const NativeHttpException('disposed');
    final official = const [
      'ani.gamer.com.tw',
      'api.gamer.com.tw',
      'i2.bahamut.com.tw',
    ].contains(uri.host);
    if (!official) NativePlaybackSource.mediaUri(uri.toString());
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const NativeHttpException('request-origin');
    }
    final abort = Completer<void>();
    _requests.add(abort);
    try {
      return await (() async {
        final request = http.AbortableRequest(
          'GET',
          uri,
          abortTrigger: abort.future,
        )..followRedirects = false;
        request.headers.addAll({
          'User-Agent': userAgent,
          'Origin': 'https://ani.gamer.com.tw',
          'Referer': _web('/animeVideo.php', {'sn': _video}).toString(),
          'Accept': '*/*',
          if (_cookies.header(uri).isNotEmpty) 'Cookie': _cookies.header(uri),
        });
        final response = await _client.send(request);
        onEvent?.call(stage, response.statusCode);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw NativeHttpException(stage, response.statusCode);
        }
        final cookie = response.headers['set-cookie'];
        if (cookie != null) _cookies.receive(uri, cookie);
        if ((response.contentLength ?? 0) > 2000000) {
          throw const NativeHttpException('response-size');
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (_disposed) throw const NativeHttpException('disposed');
          if (bytes.length + chunk.length > 2000000) {
            throw const NativeHttpException('response-size');
          }
          bytes.addAll(chunk);
        }
        final body = utf8.decode(bytes);
        if (body.contains('challenge-platform') || body.contains('cf-chl-')) {
          throw const NativeHttpException('verification-required');
        }
        return body;
      })().timeout(timeout);
    } on NativeHttpException {
      rethrow;
    } on TimeoutException {
      throw NativeHttpException('$stage-timeout');
    } catch (_) {
      throw NativeHttpException(_disposed ? 'disposed' : '$stage-transport');
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
    _cookies.clear();
    _device = '';
  }
}

/// Media advancement, never a seek distance or paused/buffering wall time.
class NativeHttpWatchClock {
  double total = 0;
  double? _position;
  Duration? _time;
  double? _terminalPosition;
  Duration? _terminalTime;

  /// Only for a decoder started at zero whose seek/rate/replay commands are
  /// unavailable. Its monotonic media position already excludes wall time
  /// spent paused or buffering; delayed plugin samples must not erase it.
  void sampleUnseekable(double position) {
    if (position.isFinite && position >= 0) total = max(total, position);
  }

  void sample({
    required double position,
    required Duration now,
    required bool playing,
    double rate = 1,
    bool completed = false,
  }) {
    final previous = _position ?? _terminalPosition;
    final time = _time ?? _terminalTime;
    var advanced = false;
    if (previous != null && time != null) {
      final elapsed = (now - time).inMicroseconds / 1e6;
      final delta = position - previous;
      if (elapsed >= 0 &&
          elapsed <= 3 &&
          delta >= 0 &&
          delta <= elapsed * rate + .35) {
        // Native position is the measured media clock. Repeated state/timer
        // notifications with no advancement must not shorten its interval.
        total += delta;
        advanced = delta > 0;
      }
    }
    if (playing && _position == position) return;
    if (playing || _position != null || completed) {
      _terminalPosition = position;
      _terminalTime = now;
    } else if (advanced) {
      // The plugin can report its final native position after pause returns.
      // Keep the original transition deadline so paused samples cannot extend
      // the short settlement window indefinitely.
      _terminalPosition = position;
    }
    _position = playing ? position : null;
    _time = playing ? now : null;
  }

  void discontinuity() {
    _position = null;
    _time = null;
    _terminalPosition = null;
    _terminalTime = null;
  }
}
