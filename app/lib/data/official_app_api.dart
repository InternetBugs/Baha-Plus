import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/models.dart';

/// Anonymous, read-only App catalog and video metadata.
///
/// Playback authorization, account data, advertisements and watch progress
/// continue to belong to the existing official browser session.
class OfficialAppApi {
  OfficialAppApi({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client() {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
  }

  static const maxResponseBytes = 2000000;
  static final _videoId = RegExp(r'^[1-9][0-9]{0,9}$');

  final http.Client _client;
  final Duration timeout;
  final _requests = <Completer<void>>{};
  bool _disposed = false;

  Future<Catalog> fetchCatalog() async {
    final data = await _get('index.php');
    try {
      return OfficialAppMetadata.catalog(data);
    } on FormatException {
      throw const OfficialAppApiException('invalid-catalog');
    } on TypeError {
      throw const OfficialAppApiException('invalid-catalog');
    }
  }

  Future<OfficialAppVideo> fetchVideo(String videoId) async {
    _validateVideoId(videoId);
    final data = await _get('video.php', {'sn': videoId});
    try {
      final video = OfficialAppVideo.fromJson(data['video'] as Json);
      if (video.videoId != videoId) {
        throw const FormatException('Episode mismatch');
      }
      return video;
    } on FormatException {
      throw const OfficialAppApiException('invalid-video');
    } on TypeError {
      throw const OfficialAppApiException('invalid-video');
    }
  }

  Future<AnimeDetail> fetchDetail({
    required String animeId,
    required String videoId,
  }) async {
    _validateVideoId(animeId);
    _validateVideoId(videoId);
    final data = await _get('video.php', {'sn': videoId});
    late final OfficialAppVideo video;
    late final Json anime;
    late final AnimeDetail detail;
    try {
      video = OfficialAppVideo.fromJson(data['video'] as Json);
      if (video.videoId != videoId || video.animeId != animeId) {
        throw const FormatException('Episode or series mismatch');
      }
      anime = data['anime'] as Json;
      detail = OfficialAppMetadata.detail(anime, video);
    } on FormatException {
      throw const OfficialAppApiException('invalid-detail');
    } on TypeError {
      throw const OfficialAppApiException('invalid-detail');
    }

    // Reviews use the verified detail's fanId, not its animeSn or acgSn.
    final fanId = anime['fanId']?.toString();
    if (fanId == null || !_videoId.hasMatch(fanId)) return detail;
    try {
      final rating = await fetchRating(fanId);
      return OfficialAppMetadata.detail(anime, video, rating: rating);
    } on OfficialAppApiException {
      if (_disposed) rethrow;
      // An unavailable review service must leave the episodes usable.
      return detail;
    }
  }

  Future<RatingSummary> fetchRating(String fanId) async {
    _validateVideoId(fanId);
    final data = await _getData(
      Uri.https('api.gamer.com.tw', '/acg/v1/reviews_list.php', {
        'sn': fanId,
        't': '4',
      }),
    );
    try {
      final rating = data['rating'] as Json;
      final chart = rating['star_chart'] as Json;
      if (chart.length != 5 ||
          ![1, 2, 3, 4, 5].every((star) => chart.containsKey('$star'))) {
        throw const FormatException('Invalid star chart');
      }
      final summary = RatingSummary.fromJson({
        'value': rating['count'] == 0 && rating['avg'] == null
            ? 0
            : rating['avg'],
        'count': rating['count'],
        'distribution': [for (var star = 1; star <= 5; star++) chart['$star']],
      });
      if (summary.distribution.fold<int>(0, (sum, count) => sum + count) !=
          summary.count) {
        throw const FormatException('Inconsistent rating count');
      }
      return summary;
    } on FormatException {
      throw const OfficialAppApiException('invalid-rating');
    } on TypeError {
      throw const OfficialAppApiException('invalid-rating');
    }
  }

  /// Public search/artwork data, always anonymous even for a signed-in app.
  Future<Json> fetchPublicCatalog(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != 'api.gamer.com.tw' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        !const [
          '/anime/v1/search.php',
          '/anime/v1/anime_list.php',
        ].contains(uri.path)) {
      throw const OfficialAppApiException('invalid-catalog-endpoint');
    }
    return _request(uri);
  }

  static void _validateVideoId(String videoId) {
    if (!_videoId.hasMatch(videoId)) {
      throw const OfficialAppApiException('invalid-video-id');
    }
  }

  Future<Json> _get(String endpoint, [Map<String, String>? query]) => _getData(
    Uri.https('api.gamer.com.tw', '/mobile_app/anime/v4/$endpoint', query),
  );

  Future<Json> _getData(Uri uri) async {
    final body = await _request(uri);
    if (body['error'] != null) {
      throw OfficialAppApiException(
        'official-rejected',
        officialCode: _officialCode(body),
      );
    }
    if (body['data'] is! Json) {
      throw OfficialAppApiException(
        'invalid-response',
        officialCode: _officialCode(body),
      );
    }
    return body['data'] as Json;
  }

  static int? _officialCode(Json body) {
    final error = body['error'];
    final nestedCode = error is Json ? error['code'] : null;
    final code = nestedCode is int ? nestedCode : body['code'];
    return code is int ? code : null;
  }

  Future<Json> _request(Uri uri) async {
    if (_disposed) throw const OfficialAppApiException('disposed');
    final abort = Completer<void>();
    _requests.add(abort);
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
    try {
      return await _read(request).timeout(timeout);
    } on OfficialAppApiException {
      rethrow;
    } on TimeoutException {
      throw const OfficialAppApiException('timeout');
    } on FormatException {
      throw const OfficialAppApiException('invalid-json');
    } catch (error) {
      // Client exceptions can contain URLs or response text. Only fixed codes
      // leave this transport.
      throw OfficialAppApiException(
        _disposed
            ? 'disposed'
            : error is HandshakeException
            ? 'tls'
            : 'network',
        socketErrorCode: error is SocketException
            ? error.osError?.errorCode
            : null,
      );
    } finally {
      if (!abort.isCompleted) abort.complete();
      _requests.remove(abort);
    }
  }

  Future<Json> _read(http.BaseRequest request) async {
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw OfficialAppApiException('http-${response.statusCode}');
    }
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (contentType != 'application/json') {
      throw const OfficialAppApiException('not-json');
    }
    if ((response.contentLength ?? 0) > maxResponseBytes) {
      throw const OfficialAppApiException('response-too-large');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const OfficialAppApiException('response-too-large');
      }
      bytes.add(chunk);
    }
    final body = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (body is! Json) {
      throw const OfficialAppApiException('invalid-response');
    }
    if (_disposed) throw const OfficialAppApiException('disposed');
    return body;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in _requests) {
      if (!request.isCompleted) request.complete();
    }
    _client.close();
  }
}

/// Maps only public fields; favorites, breakpoints and account flags are ignored.
class OfficialAppMetadata {
  static Catalog catalog(Json data, {DateTime? now}) {
    final instant = (now ?? DateTime.now()).toUtc();
    final taipei = instant.add(const Duration(hours: 8));
    final items = <String, Anime>{};
    final seasonal = (data['newAnime'] as Json)['date'] as List;
    for (final (section, records) in [
      ('season', seasonal),
      ('hot', data['hotAnime'] as List),
      ('new', data['newAdded'] as List),
    ]) {
      if (records.length > 5000) {
        throw const FormatException('Too many catalog entries');
      }
      for (final raw in records) {
        final record = raw as Json;
        final id = OfficialAppVideo._id(record['animeSn']);
        final old = items[id];
        final isSeason = section == 'season';
        final cover = _image(record['cover']);
        final videoId = record['videoSn']?.toString();
        final info = OfficialAppVideo._text(record['info'], 500);
        final week = int.tryParse(record['week']?.toString() ?? '');
        final item = Anime.fromJson({
          'id': id,
          'title': OfficialAppVideo._text(record['title'], 499, required: true),
          'cover': cover,
          if (!isSeason) 'poster': cover,
          if (videoId != null && OfficialAppApi._videoId.hasMatch(videoId))
            'latestVideoId': videoId,
          'episodeLabel': isSeason
              ? OfficialAppVideo._text(record['volume'], 100)
              : RegExp(r'共\s*(\d+)\s*集').firstMatch(info)?.group(0),
          if (isSeason && week != null && week >= 1 && week <= 7)
            'updateDay': week % 7,
          if (isSeason) 'updateTime': _time(record['upTimeHours']),
          if (isSeason) 'updateDate': _date(record['upTime'], taipei),
          'views': _views(record['popular']),
          'year': RegExp(r'\d{4}/\d{2}').firstMatch(info)?.group(0),
          // Keep the timeline's episode thumbnail, video and update date when
          // a second section supplies the same series' main visual.
          if (old != null) ...old.toJson(),
          if (!isSeason) 'poster': cover,
          'sections': {...?old?.sections, section}.toList(),
        });
        items[id] = item;
      }
    }
    final result = Catalog(
      items: items.values.toList(growable: false),
      fetchedAt: instant.toIso8601String(),
    );
    if (!result.isValid) throw const FormatException('Invalid App catalog');
    return result;
  }

  static AnimeDetail detail(
    Json anime,
    OfficialAppVideo video, {
    RatingSummary? rating,
  }) {
    if (OfficialAppVideo._id(anime['animeSn']) != video.animeId) {
      throw const FormatException('Unexpected series');
    }
    final episodes = <String, Json>{};
    final groups = anime['episodes'] as Json;
    var total = 0;
    for (final rawGroup in groups.values) {
      final group = rawGroup as List;
      total += group.length;
      if (total > 5000) throw const FormatException('Too many episodes');
      for (final raw in group) {
        final record = raw as Json;
        final id = OfficialAppVideo._id(record['videoSn']);
        final label = record['episode']?.toString();
        if (label == null || label.trim().isEmpty || label.length > 100) {
          throw const FormatException('Invalid episode label');
        }
        if (episodes.containsKey(id)) {
          throw const FormatException('Repeated episode');
        }
        episodes[id] = {'id': id, 'label': label};
      }
    }
    if (!episodes.containsKey(video.videoId)) {
      throw const FormatException('Requested episode absent');
    }
    final metadata = <Json>[];
    void add(String label, dynamic value) {
      final text = OfficialAppVideo._text(value, 4000);
      if (text.isNotEmpty) metadata.add({'label': label, 'value': text});
    }

    final seasonStart = OfficialAppVideo._text(anime['seasonStart'], 100);
    add('年份', RegExp(r'^\d{4}/\d{2}').firstMatch(seasonStart)?.group(0));
    add('分級說明', video.ratingDescription);
    final tags = anime['tags'];
    if (tags != null) {
      if (tags is! List || tags.length > 100) {
        throw const FormatException('Invalid tags');
      }
      add(
        '作品類型',
        tags.map((tag) => OfficialAppVideo._text(tag, 100)).join('、'),
      );
    }
    add('導演', anime['director']);
    add('製作廠商', anime['maker']);
    add('代理商', anime['publisher']);
    final score = anime['score'];
    if (score != null) {
      if (score is! num || !score.isFinite || score < 0 || score > 5) {
        throw const FormatException('Invalid score');
      }
      // Keep the available score when full review statistics are unavailable.
      if (rating == null) add('評分', '$score / 5');
    }
    final content = OfficialAppVideo._text(anime['content'], 200000);
    return AnimeDetail.fromJson({
      'title': OfficialAppVideo._text(
        anime['title'],
        499,
        required: true,
      ).replaceFirst(RegExp(r'\s*\[[^\]]+\]\s*$'), ''),
      'description': content
          .split(
            RegExp(r'[＜<](?:製作團隊|制作团队|STAFF|CAST)[＞>]', caseSensitive: false),
          )
          .first
          .trim(),
      'poster': _image(anime['cover']),
      'episodes': episodes.values.toList(growable: false),
      'metadata': metadata,
      if (rating != null) 'rating': rating.toJson(),
    });
  }

  static String _image(dynamic value) {
    final text = OfficialAppVideo._text(value, 4096, required: true);
    final uri = Uri.tryParse(text);
    if (!OfficialSite.validImage(text) ||
        uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443) {
      throw const FormatException('Invalid public artwork');
    }
    return text;
  }

  static String? _views(dynamic value) {
    if (value == null) return null;
    final text = value.toString();
    if (!RegExp(r'^\d{1,15}$').hasMatch(text)) {
      throw const FormatException('Invalid view count');
    }
    return text;
  }

  static String? _time(dynamic value) {
    final text = OfficialAppVideo._text(value, 5);
    if (text.isEmpty) return null;
    if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(text)) {
      throw const FormatException('Invalid update time');
    }
    return text;
  }

  static String? _date(dynamic value, DateTime today) {
    final text = OfficialAppVideo._text(value, 20);
    if (text.isEmpty) return null;
    final match = RegExp(r'^(\d{1,2})/(\d{1,2})$').firstMatch(text);
    if (match == null) throw const FormatException('Invalid update date');
    final month = int.parse(match[1]!);
    final day = int.parse(match[2]!);
    var year = today.year;
    if (month - today.month > 6) year--;
    if (month - today.month < -6) year++;
    final result =
        '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
    if (!Catalog.validDate(result)) {
      throw const FormatException('Invalid update date');
    }
    return result;
  }
}

/// Descriptive metadata only: a rating or quality label grants no entitlement.
class OfficialAppVideo {
  OfficialAppVideo.fromJson(Json video)
    : videoId = _id(video['videoSn']),
      animeId = _id(video['animeSn']),
      title = _text(video['title'], 500, required: true),
      durationMinutes = _duration(video['duration']),
      rating = _rating(video['rating']),
      ratingDescription = _text(video['ratingDesc'], 2000),
      qualityLabel = _text(video['quality'], 64);

  final String videoId, animeId, title, ratingDescription, qualityLabel;
  final double durationMinutes;
  final int rating;

  static String _id(dynamic value) {
    final text = value?.toString() ?? '';
    if (!OfficialAppApi._videoId.hasMatch(text)) {
      throw const FormatException('Invalid App video identifier');
    }
    return text;
  }

  static String _text(dynamic value, int maximum, {bool required = false}) {
    if (value == null && !required) return '';
    if (value is! String ||
        value.length > maximum ||
        (required && value.trim().isEmpty)) {
      throw const FormatException('Invalid App video text');
    }
    return value.trim();
  }

  static double _duration(dynamic value) {
    if (value is! num || !value.isFinite || value < 0 || value > 2880) {
      throw const FormatException('Invalid App video duration');
    }
    return value.toDouble();
  }

  static int _rating(dynamic value) {
    if (value is! int || value < 0 || value > 255) {
      throw const FormatException('Invalid App video rating');
    }
    return value;
  }
}

class OfficialAppApiException implements Exception {
  const OfficialAppApiException(
    this.code, {
    this.socketErrorCode,
    this.officialCode,
  });
  final String code;
  final int? socketErrorCode, officialCode;

  @override
  String toString() => 'OfficialAppApiException($code)';
}
