import 'dart:async';
import '../core/models.dart';

typedef PublicCatalogTransport =
    Future<Json> Function(Uri uri, {required bool useAccount});

abstract interface class AnimeSearch {
  Future<List<Anime>> search(String query, {bool useAccount = true});
  Future<List<Anime>> recentSeries();
  void dispose();
}

class OfficialAnimeSearch implements AnimeSearch {
  OfficialAnimeSearch({required this.toTraditional});
  final String Function(String) toTraditional;
  PublicCatalogTransport? _transport;
  final _ready = Completer<void>();
  bool _disposed = false;
  static const timeout = Duration(seconds: 12);

  void useTransport(PublicCatalogTransport transport) {
    if (_disposed) return;
    _transport = transport;
    if (!_ready.isCompleted) _ready.complete();
  }

  @override
  Future<List<Anime>> search(String query, {bool useAccount = true}) async {
    final input = String.fromCharCodes(query.trim().runes.take(100));
    if (input.isEmpty) return [];
    final queries = {input, toTraditional(input)};
    final responses = await Future.wait(
      queries.map(
        (keyword) => _request('/anime/v1/search.php', {
          'kw': keyword,
        }, useAccount: useAccount),
      ),
    );
    return {
      for (final items in responses)
        for (final item in items) item.id: item,
    }.values.toList();
  }

  @override
  Future<List<Anime>> recentSeries() async {
    final pages = await Future.wait([
      for (final page in [1, 2])
        _request('/anime/v1/anime_list.php', {
          'page': '$page',
        }, useAccount: false),
    ]);
    return [for (final items in pages) ...items];
  }

  Future<List<Anime>> _request(
    String path,
    Map<String, String> query, {
    bool useAccount = true,
  }) async {
    final uri = Uri.https('api.gamer.com.tw', path, query);
    await _ready.future.timeout(timeout);
    if (_disposed || _transport == null) {
      throw StateError('Official catalog connection unavailable');
    }
    return parseResponse(await _transport!(uri, useAccount: useAccount));
  }

  static List<Anime> parseResponse(Json body) {
    final records = (body['data'] as Json)['animeList'] as List;
    if (records.length > 5000) {
      throw const FormatException('Too many search results');
    }
    return records.map((raw) {
      final item = raw as Json;
      final id = '${item['animeSn']}';
      final video = '${item['videoSn']}';
      final title = (item['title'] as String).trim();
      final cover = item['cover'] as String;
      final uri = Uri.tryParse(cover);
      if (!OfficialSite.validId(id) ||
          title.isEmpty ||
          !OfficialSite.validImage(cover) ||
          uri == null ||
          uri.userInfo.isNotEmpty ||
          uri.port != 443) {
        throw const FormatException('Invalid official search result');
      }
      final episodes = item['totalEpisode'];
      return Anime.fromJson({
        'id': id,
        'title': title,
        'cover': cover,
        'poster': cover,
        if (OfficialSite.validId(video)) 'latestVideoId': video,
        if (episodes is int && episodes > 0) 'episodeLabel': '$episodes 集',
        'year': RegExp(
          r'\d{4}(?:/\d{2})?',
        ).firstMatch(item['dateInfo'] as String? ?? '')?.group(0),
        'sections': <String>[],
      });
    }).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    _transport = null;
    if (!_ready.isCompleted) _ready.complete();
  }
}
