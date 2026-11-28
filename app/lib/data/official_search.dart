import 'dart:async';
import '../core/models.dart';

typedef PublicCatalogTransport =
    Future<Json> Function(Uri uri, {required bool useAccount});
typedef CancellablePublicCatalogTransport =
    Future<Json> Function(
      Uri uri, {
      required bool useAccount,
      Future<void>? cancel,
    });

abstract interface class AnimeSearch {
  Future<List<Anime>> search(String query, {bool useAccount = true});
  Future<List<Anime>> recentSeries();
  void dispose();
}

class OfficialAnimeSearch implements AnimeSearch {
  OfficialAnimeSearch({required this.toTraditional, this.foldingReady});
  final String Function(String) toTraditional;
  final Future<void>? foldingReady;
  PublicCatalogTransport? _transport;
  CancellablePublicCatalogTransport? _cancellableTransport;
  final _ready = Completer<void>();
  final _cache = <(String, bool), (List<Anime>, DateTime)>{};
  int _cacheGeneration = 0;
  bool _disposed = false;
  static const timeout = Duration(seconds: 12);
  static final _year = RegExp(r'\d{4}(?:/\d{2})?');

  void useTransport(
    PublicCatalogTransport transport, {
    CancellablePublicCatalogTransport? cancellable,
  }) {
    if (_disposed) return;
    reset();
    _transport = transport;
    _cancellableTransport = cancellable;
    if (!_ready.isCompleted) _ready.complete();
  }

  @override
  Future<List<Anime>> search(
    String query, {
    bool useAccount = true,
    Future<void>? cancel,
  }) async {
    final input = String.fromCharCodes(query.trim().runes.take(100));
    if (input.isEmpty) return [];
    final key = (input, useAccount);
    final cached = _cache.remove(key);
    if (cached != null && DateTime.now().isBefore(cached.$2)) {
      _cache[key] = cached;
      return cached.$1;
    }
    final generation = _cacheGeneration;
    if (foldingReady case final ready?) await ready;
    final queries = {input, toTraditional(input)};
    Object? failure;
    StackTrace? failureStack;
    final responses = await Future.wait(
      queries.map((keyword) async {
        try {
          return await _request(
            '/anime/v1/search.php',
            {'kw': keyword},
            useAccount: useAccount,
            cancel: cancel,
          );
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
          return null;
        }
      }),
    );
    if (responses.every((response) => response == null)) {
      Error.throwWithStackTrace(failure!, failureStack!);
    }
    final results = List<Anime>.unmodifiable(
      {
        for (final items in responses.nonNulls)
          for (final item in items) item.id: item,
      }.values,
    );
    if (failure == null && generation == _cacheGeneration && !_disposed) {
      _cache[key] = (results, DateTime.now().add(const Duration(minutes: 2)));
      if (_cache.length > 20) _cache.remove(_cache.keys.first);
    }
    return results;
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
    Future<void>? cancel,
  }) async {
    final uri = Uri.https('api.gamer.com.tw', path, query);
    await _ready.future.timeout(timeout);
    if (_disposed || _transport == null) {
      throw StateError('Official catalog connection unavailable');
    }
    final cancellable = _cancellableTransport;
    return parseResponse(
      cancellable == null
          ? await _transport!(uri, useAccount: useAccount)
          : await cancellable(uri, useAccount: useAccount, cancel: cancel),
    );
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
        'year': _year.firstMatch(item['dateInfo'] as String? ?? '')?.group(0),
        'sections': <String>[],
      });
    }).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
    _transport = null;
    _cancellableTransport = null;
    if (!_ready.isCompleted) _ready.complete();
  }

  void reset() {
    _cacheGeneration++;
    _cache.clear();
  }
}
