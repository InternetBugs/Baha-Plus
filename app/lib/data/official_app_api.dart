import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'http_pool.dart';
import 'official_search.dart';
import 'official_user_agent.dart';

/// Anonymous, read-only App catalog and video metadata.
///
/// Playback authorization, account data, advertisements and watch progress
/// continue to belong to the existing official browser session.
class OfficialAppApi {
  OfficialAppApi({
    http.Client? client,
    http.Client Function()? clientFactory,
    String? userAgent,
    this.timeout = const Duration(seconds: 12),
    this.retryDelay = const Duration(milliseconds: 250),
  }) : _userAgent = userAgent {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
    if (retryDelay < Duration.zero) {
      throw ArgumentError.value(retryDelay, 'retryDelay');
    }
    _pool = RetryingHttpClientPool(
      client: client,
      clientFactory: clientFactory,
    );
  }

  static const maxResponseBytes = 2000000;
  static final _videoId = RegExp(r'^[1-9][0-9]{0,9}$');

  final String? _userAgent;
  final Duration timeout;
  final Duration retryDelay;
  late final RetryingHttpClientPool _pool;
  bool _disposed = false;

  Future<Catalog> fetchCatalog() async {
    final data = await _get('index.php', maxRetries: 2, retryTimeout: true);
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
    final data = await _get(
      'video.php',
      query: {'sn': videoId},
      maxRetries: 1,
      retryTimeout: false,
    );
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
    bool includeRating = true,
    Future<void>? cancel,
  }) async {
    _validateVideoId(animeId);
    _validateVideoId(videoId);
    final data = await _get(
      'video.php',
      query: {'sn': videoId},
      maxRetries: 1,
      retryTimeout: true,
      cancel: cancel,
    );
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
    final fanId = detail.fanId;
    if (!includeRating || fanId == null) return detail;
    try {
      final rating = await fetchRating(fanId, cancel: cancel);
      return rating == null
          ? detail
          : OfficialAppMetadata.attachRating(detail, rating);
    } on OfficialAppApiException catch (error) {
      if (_disposed || error.code == 'cancelled') rethrow;
      // An unavailable review service must leave the episodes usable.
      return detail;
    }
  }

  Future<RatingSummary?> fetchRating(
    String fanId, {
    Future<void>? cancel,
  }) async {
    _validateVideoId(fanId);
    final data = await _getData(
      Uri.https('api.gamer.com.tw', '/acg/v1/reviews_list.php', {
        'sn': fanId,
        't': '4',
      }),
      maxRetries: 0,
      retryTimeout: false,
      cancel: cancel,
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
  Future<Json> fetchPublicCatalog(Uri uri, {Future<void>? cancel}) {
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
    return _request(uri, maxRetries: 1, retryTimeout: false, cancel: cancel);
  }

  Future<({List<Anime> items, bool hasMore})> fetchLibraryPage(
    int page, {
    Future<void>? cancel,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    final body = await fetchPublicCatalog(
      Uri.https('api.gamer.com.tw', '/anime/v1/anime_list.php', {
        'page': '$page',
      }),
      cancel: cancel,
    );
    try {
      final items = OfficialAnimeSearch.parseResponse(body);
      final data = body['data'] as Json;
      final totalPages = int.tryParse(
        '${data['totalPage'] ?? data['totalPages']}',
      );
      final hasMore = data['hasMore'];
      return (
        items: items,
        hasMore:
            items.isNotEmpty &&
            (hasMore is bool
                ? hasMore
                : totalPages == null || page < totalPages),
      );
    } on FormatException {
      throw const OfficialAppApiException('invalid-catalog');
    } on TypeError {
      throw const OfficialAppApiException('invalid-catalog');
    }
  }

  static void _validateVideoId(String videoId) {
    if (!_videoId.hasMatch(videoId)) {
      throw const OfficialAppApiException('invalid-video-id');
    }
  }

  Future<Json> _get(
    String endpoint, {
    Map<String, String>? query,
    int maxRetries = 1,
    bool retryTimeout = false,
    Future<void>? cancel,
  }) => _getData(
    Uri.https('api.gamer.com.tw', '/mobile_app/anime/v4/$endpoint', query),
    maxRetries: maxRetries,
    retryTimeout: retryTimeout,
    cancel: cancel,
  );

  Future<Json> _getData(
    Uri uri, {
    int maxRetries = 1,
    bool retryTimeout = false,
    Future<void>? cancel,
  }) async {
    final body = await _request(
      uri,
      maxRetries: maxRetries,
      retryTimeout: retryTimeout,
      cancel: cancel,
    );
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

  Future<Json> _request(
    Uri uri, {
    int maxRetries = 1,
    bool retryTimeout = false,
    Future<void>? cancel,
  }) async {
    try {
      return await _pool.run(
        (client, abort, attempt) async {
          if (_userAgent == null) await OfficialUserAgent.ensureResolved();
          final request = http.AbortableRequest('GET', uri, abortTrigger: abort)
            ..followRedirects = false
            ..persistentConnection = attempt == 0
            ..headers['Accept'] = 'application/json'
            ..headers['User-Agent'] = _userAgent ?? OfficialUserAgent.value;
          return _read(client, request);
        },
        timeout: timeout,
        maxRetries: maxRetries,
        cancel: cancel,
        retryAfter: (error, attempt) {
          final delay = retryDelay * (attempt == 0 ? 1 : 3);
          if (error is _UnexpectedStatus) {
            if (error.status == 429) return error.retryAfter ?? delay;
            if (error.status >= 500 && error.status <= 599) return delay;
          }
          if (error is TimeoutException) return retryTimeout ? delay : null;
          return RetryingHttpClientPool.isTransportError(error) ? delay : null;
        },
      );
    } on HttpPoolCancelled catch (error) {
      throw OfficialAppApiException(error.disposed ? 'disposed' : 'cancelled');
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
            : error is TlsException
            ? 'tls'
            : 'network',
        socketErrorCode: error is SocketException
            ? error.osError?.errorCode
            : null,
      );
    }
  }

  Future<Json> _read(http.Client client, http.BaseRequest request) async {
    final response = await client.send(request);
    if (response.statusCode != 200) {
      await cancelResponse(response);
      throw _UnexpectedStatus(
        response.statusCode,
        response.statusCode == 429
            ? _parseRetryAfter(response.headers['retry-after'])
            : null,
      );
    }
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (contentType != 'application/json') {
      await cancelResponse(response);
      throw const OfficialAppApiException('not-json');
    }
    if ((response.contentLength ?? 0) > maxResponseBytes) {
      await cancelResponse(response);
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
    _pool.dispose();
  }

  static Duration? _parseRetryAfter(String? raw) {
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 5));
    try {
      final delay = HttpDate.parse(raw).difference(DateTime.now());
      return Duration(milliseconds: delay.inMilliseconds.clamp(0, 5000));
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }
}

class _UnexpectedStatus extends OfficialAppApiException {
  _UnexpectedStatus(this.status, this.retryAfter) : super('http-$status');

  final int status;
  final Duration? retryAfter;
}

/// Maps only public fields; favorites, breakpoints and account flags are ignored.
class OfficialAppMetadata {
  static final _addedDate = RegExp(r'上架日[：:]\s*(\d{1,2}/\d{1,2})');
  static final _episodeCount = RegExp(r'共\s*(\d+)\s*集');
  static final _year = RegExp(r'\d{4}/\d{2}');
  static final _leadingYear = RegExp(r'^\d{4}/\d{2}');
  static final _episodeSuffix = RegExp(r'\s*\[[^\]]+\]\s*$');
  static final _credits = RegExp(
    r'[＜<](?:製作團隊|制作团队|STAFF|CAST)[＞>]',
    caseSensitive: false,
  );
  static final _viewCount = RegExp(r'^\d{1,15}$');
  static final _updateTime = RegExp(r'^(\d{1,2}):([0-5]\d)(?::[0-5]\d)?$');
  static final _updateDate = RegExp(r'^(\d{1,2})/(\d{1,2})$');

  static Catalog catalog(Json data, {DateTime? now}) {
    final instant = (now ?? DateTime.now()).toUtc();
    final taipei = instant.add(const Duration(hours: 8));
    final items = <String, Anime>{};
    final newAnime = data['newAnime'] as Json;
    final seasonal = newAnime['date'] as List;
    final seasonalPopular = newAnime['popular'] == null
        ? const <dynamic>[]
        : newAnime['popular'] as List;
    final hot = data['hotAnime'] == null
        ? const <dynamic>[]
        : data['hotAnime'] as List;
    final added = data['newAdded'] == null
        ? const <dynamic>[]
        : data['newAdded'] as List;
    for (final (section, records) in [
      ('season', seasonal),
      ('hot', hot),
      ('new', added),
    ]) {
      if (records.length > 5000) {
        throw const FormatException('Too many catalog entries');
      }
      for (final raw in records) {
        final record = raw as Json;
        final id = OfficialAppVideo._id(record['animeSn']);
        final old = items[id];
        final isSeason = section == 'season';
        final isNew = section == 'new';
        final cover = _image(record['cover']);
        final videoId = record['videoSn']?.toString();
        final info = OfficialAppVideo._text(record['info'], 500);
        final week = int.tryParse(record['week']?.toString() ?? '');
        final title = OfficialAppVideo._text(
          record['title'],
          499,
          required: true,
        );
        final label = isSeason
            ? _label(record['volume'], 100)
            : _episodeCount.firstMatch(info)?.group(0);
        final latestVideo =
            videoId != null && OfficialAppApi._videoId.hasMatch(videoId)
            ? videoId
            : null;
        final views = _views(record['popular']);
        final year = _year.firstMatch(info)?.group(0);
        final updateTime = isSeason ? _time(record['upTimeHours']) : null;
        final updateDate = isSeason ? _date(record['upTime'], taipei) : null;
        final updateDay = isSeason && week != null && week >= 1 && week <= 7
            ? week % 7
            : null;
        final addedDate = isNew ? _addedDate.firstMatch(info)?.group(1) : null;
        final item = old == null
            ? Anime.fromJson({
                'id': id,
                'title': title,
                'cover': cover,
                if (!isSeason) 'poster': cover,
                'latestVideoId': ?latestVideo,
                'episodeLabel': label,
                'updateDay': ?updateDay,
                'updateTime': ?updateTime,
                'updateDate': ?updateDate,
                'views': views,
                'year': year,
                'addedDate': ?addedDate,
                'sections': [section],
              })
            : old.copyWith(
                poster: isSeason ? old.poster : cover,
                latestVideoId: old.latestVideoId ?? latestVideo,
                episodeLabel: old.episodeLabel ?? label,
                updateDay: old.updateDay ?? updateDay,
                updateTime: old.updateTime ?? updateTime,
                updateDate: old.updateDate ?? updateDate,
                addedDate: addedDate ?? old.addedDate,
                views: old.views ?? views,
                year: old.year ?? year,
                sections: {...old.sections, section}.toList(),
              );
        items[id] = item;
      }
    }
    if (seasonalPopular.length > 5000) {
      throw const FormatException('Too many seasonal popular entries');
    }
    final seasonalPopularIds = <String>[];
    final seenPopularIds = <String>{};
    for (final raw in seasonalPopular) {
      final record = raw as Json;
      final id = OfficialAppVideo._id(record['animeSn']);
      if (items.containsKey(id) && seenPopularIds.add(id)) {
        seasonalPopularIds.add(id);
      }
    }
    final collections = _collections(data['category']);
    final result = Catalog(
      items: items.values.toList(growable: false),
      fetchedAt: instant.toIso8601String(),
      seasonalPopularIds: List<String>.unmodifiable(seasonalPopularIds),
      collections: collections,
    );
    if (!result.isValid) throw const FormatException('Invalid App catalog');
    return result;
  }

  static List<AnimeCollection> _collections(dynamic rawCategories) {
    if (rawCategories == null) return const [];
    final records = rawCategories as List;
    if (records.length > 100) {
      throw const FormatException('Too many catalog collections');
    }
    // Official index.php splits large expiring-license groups into repeated
    // category blocks sharing the same title. Merge identical titles in order.
    final grouped =
        <String, ({String intro, bool expiring, Map<String, Anime> items})>{};
    for (final raw in records) {
      final record = raw as Json;
      final title = OfficialAppVideo._text(
        record['title'],
        499,
        required: true,
      );
      final intro = OfficialAppVideo._text(record['intro'], 2000);
      final list = record['list'] as List;
      if (list.length > 500) {
        throw const FormatException('Too many collection entries');
      }
      final expiring = title.contains('到期') || title.contains('下架');
      final bucket = grouped.putIfAbsent(
        title,
        () => (intro: intro, expiring: expiring, items: <String, Anime>{}),
      );
      for (final entryRaw in list) {
        final entry = entryRaw as Json;
        final id = OfficialAppVideo._id(entry['animeSn']);
        if (bucket.items.containsKey(id)) continue;
        final cover = _image(entry['cover']);
        final videoId = entry['videoSn']?.toString();
        final info = OfficialAppVideo._text(entry['info'], 500);
        bucket.items[id] = Anime.fromJson({
          'id': id,
          'title': OfficialAppVideo._text(entry['title'], 499, required: true),
          'cover': cover,
          'poster': cover,
          if (videoId != null && OfficialAppApi._videoId.hasMatch(videoId))
            'latestVideoId': videoId,
          'episodeLabel': _episodeCount.firstMatch(info)?.group(0),
          'views': _views(entry['popular']),
          'year': _year.firstMatch(info)?.group(0),
          'sections': const <String>[],
        });
      }
    }
    var index = 0;
    return List<AnimeCollection>.unmodifiable([
      for (final entry in grouped.entries)
        if (entry.value.items.isNotEmpty)
          AnimeCollection(
            id: entry.value.expiring
                ? 'expiring-${++index}'
                : 'topic-${++index}',
            title: entry.key,
            intro: entry.value.intro,
            items: List<Anime>.unmodifiable(entry.value.items.values),
            expiring: entry.value.expiring,
          ),
    ]);
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
    add('年份', _leadingYear.firstMatch(seasonStart)?.group(0));
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
    final rawFanId = '${anime['fanId']}';
    final fanId = OfficialAppApi._videoId.hasMatch(rawFanId) ? rawFanId : null;
    return AnimeDetail.fromJson(
      {
        'title': OfficialAppVideo._text(
          anime['title'],
          499,
          required: true,
        ).replaceFirst(_episodeSuffix, ''),
        'description': content.split(_credits).first.trim(),
        'poster': _image(anime['cover']),
        'episodes': episodes.values.toList(growable: false),
        'metadata': metadata,
      },
      fanId: fanId,
      rating: rating,
    );
  }

  static AnimeDetail attachRating(AnimeDetail detail, RatingSummary rating) =>
      detail.copyWith(
        rating: rating,
        metadata: detail.metadata.where((item) => item.label != '評分').toList(),
      );

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

  static String _label(dynamic value, int maximum) {
    if (value == null) return '';
    if (value is num) return OfficialAppVideo._text('$value', maximum);
    return OfficialAppVideo._text(value, maximum);
  }

  static String? _views(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    if (!_viewCount.hasMatch(text)) {
      throw const FormatException('Invalid view count');
    }
    return text;
  }

  static String? _time(dynamic value) {
    final text = OfficialAppVideo._text(value, 16);
    if (text.isEmpty) return null;
    final match = _updateTime.firstMatch(text);
    if (match == null) {
      throw const FormatException('Invalid update time');
    }
    final hour = int.parse(match[1]!);
    if (hour > 23) {
      throw const FormatException('Invalid update time');
    }
    return '${hour.toString().padLeft(2, '0')}:${match[2]!}';
  }

  static String? _date(dynamic value, DateTime today) {
    final text = OfficialAppVideo._text(value, 20);
    if (text.isEmpty) return null;
    final match = _updateDate.firstMatch(text);
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
