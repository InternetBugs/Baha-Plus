import 'dart:convert';
import 'dart:math';
import 'models.dart';
import 'playback_state.dart';

enum BrowserIntent {
  idle,
  catalog,
  search,
  detail,
  account,
  accountRefresh,
  favorite,
  play,
  browse,
}

class BrowserRequest {
  BrowserRequest({
    required this.intent,
    this.animeId,
    this.favoriteTarget,
    this.query,
    this.videoId,
    String? id,
  }) : id =
           id ??
           List.generate(
             24,
             (_) =>
                 Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
           ).join();

  final BrowserIntent intent;
  final String id;
  final String? animeId, query, videoId;
  final bool? favoriteTarget;

  Json? accept(
    String raw, {
    required Uri origin,
    required Uri source,
    required bool isMainFrame,
  }) {
    if (!isMainFrame ||
        !OfficialSite.trustedOrigin(origin) ||
        !OfficialSite.trustedOrigin(source) ||
        utf8.encode(raw).length >= 5000000) {
      return null;
    }
    try {
      final body = jsonDecode(raw) as Json;
      if (body['requestId'] != id) return null;
      final type = body['type'];
      if (type == 'verification-required') {
        return intent != BrowserIntent.idle && intent != BrowserIntent.browse
            ? body
            : null;
      }
      switch (intent) {
        case BrowserIntent.catalog:
          if (type != 'catalog' ||
              !const ['/', '/index.php'].contains(source.path)) {
            return null;
          }
          Catalog.fromJson(body);
        case BrowserIntent.search:
          if (type != 'search' ||
              source.path != '/search.php' ||
              query == null ||
              source.queryParameters['keyword'] !=
                  String.fromCharCodes(query!.runes.take(100))) {
            return null;
          }
          final items = _animes(body['items'], maximum: 5000);
          if (!Catalog.validTimestamp(body['fetchedAt'] as String) ||
              items.map((e) => e.id).toSet().length != items.length) {
            return null;
          }
        case BrowserIntent.detail:
          if (body['id'] != animeId ||
              animeId == null ||
              !OfficialSite.validId(animeId!)) {
            return null;
          }
          if (type == 'detail') {
            AnimeDetail.fromJson(body['detail'] as Json);
          } else if (type != 'detail-error') {
            return null;
          }
        case BrowserIntent.account:
        case BrowserIntent.accountRefresh:
          if (type == 'account-synced') {
            _animes(body['favorites'], maximum: 10000);
            final history = (body['history'] as List)
                .map((item) => WatchEntry.fromJson(item as Json))
                .toList();
            if (history.length > 1000 ||
                history.map((e) => e.anime.id).toSet().length !=
                    history.length) {
              return null;
            }
          } else if (type != 'account-guest' && type != 'account-error') {
            return null;
          }
        case BrowserIntent.favorite:
          if (type == 'favorite-complete') {
            if (body['id'] != animeId ||
                favoriteTarget == null ||
                body['saved'] != favoriteTarget) {
              return null;
            }
          } else if (type == 'favorite-error') {
            if (body['id'] != animeId) return null;
          } else if (type != 'account-guest' && type != 'account-error') {
            return null;
          }
        case BrowserIntent.play:
          if (animeId == null ||
              body['id'] != animeId ||
              source.path != '/animeVideo.php' ||
              !OfficialSite.validId(body['videoId'] as String) ||
              source.queryParameters['sn'] != body['videoId'] ||
              (videoId != null && videoId != body['videoId'])) {
            return null;
          }
          if (type == 'player-state') {
            PlaybackState.fromJson(body);
          } else if (type == 'player-detail') {
            AnimeDetail.fromJson(body['detail'] as Json);
          } else {
            return null;
          }
        case BrowserIntent.idle:
        case BrowserIntent.browse:
          return null;
      }
      return body;
    } catch (_) {
      return null;
    }
  }

  static List<Anime> _animes(dynamic raw, {required int maximum}) {
    final array = raw as List;
    if (array.length > maximum) throw const FormatException('Too many items');
    final items = array.map((item) => Anime.fromJson(item as Json)).toList();
    if (items.map((e) => e.id).toSet().length != items.length) {
      throw const FormatException('Duplicate series IDs');
    }
    return items;
  }
}
