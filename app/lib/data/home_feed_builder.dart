import '../core/models.dart';

class HomeFeedBuilder {
  HomeFeedBuilder(Catalog catalog) {
    final byId = {for (final anime in catalog.items) anime.id: anime};
    List<Anime> inSection(String section) => List.unmodifiable(
      catalog.items.where((anime) => anime.sections.contains(section)),
    );

    seasonal = inSection('season');
    popular = inSection('hot');
    newAdded = inSection('new');
    final ranked = [for (final id in catalog.seasonalPopularIds) ?byId[id]];
    seasonalPopular = ranked.isEmpty ? seasonal : List.unmodifiable(ranked);
    thematicCollections = List.unmodifiable(
      catalog.collections.where((collection) => !collection.expiring),
    );
    expiringCollection = _mergeExpiring(
      catalog.collections.where((collection) => collection.expiring).toList(),
    );
    feed = catalog.items.isEmpty ? HomeFeed.empty : _buildHomeFeed();
  }

  late final List<Anime> seasonal, seasonalPopular, popular, newAdded;
  late final List<AnimeCollection> thematicCollections;
  late final AnimeCollection? expiringCollection;
  late final HomeFeed feed;

  static AnimeCollection? _mergeExpiring(List<AnimeCollection> groups) {
    if (groups.isEmpty) return null;
    if (groups.length == 1) return groups.first;
    final merged = <String, Anime>{};
    for (final group in groups) {
      for (final item in group.items) {
        merged.putIfAbsent(item.id, () => item);
      }
    }
    return merged.isEmpty
        ? null
        : AnimeCollection(
            id: 'expiring-all',
            title: groups.first.title,
            items: List.unmodifiable(merged.values),
            expiring: true,
          );
  }

  static bool _isMovieOrSingleRelease(Anime item) =>
      item.title.contains('劇場版') ||
      item.title.contains('剧场版') ||
      item.title.contains('電影') ||
      item.title.contains('电影') ||
      item.episodeLabel == '共 1 集' ||
      item.episodeLabel == '共1集';

  HomeFeed _buildHomeFeed() {
    final heroes = <HomeHeroItem>[];
    final animeIds = <String>{};
    final collectionIds = <String>{};

    void addAnime(Anime anime, HomeHeroKind kind) {
      if (animeIds.add(anime.id)) {
        heroes.add(HomeHeroAnime(anime: anime, kind: kind));
      }
    }

    void addCollection(AnimeCollection collection, HomeHeroKind kind) {
      collectionIds.add(collection.id);
      heroes.add(HomeHeroCollection(collection: collection, kind: kind));
    }

    if (seasonalPopular.firstOrNull case final anime?) {
      addAnime(anime, HomeHeroKind.seasonalTop);
    }
    final candidates = newAdded.where((anime) => !animeIds.contains(anime.id));
    final highlight =
        candidates.where(_isMovieOrSingleRelease).firstOrNull ??
        candidates.firstOrNull;
    if (highlight != null) addAnime(highlight, HomeHeroKind.newRelease);
    if (thematicCollections.firstOrNull case final collection?) {
      addCollection(collection, HomeHeroKind.thematicCollection);
    }
    if (expiringCollection case final collection?) {
      addCollection(collection, HomeHeroKind.expiringCollection);
    }
    if (heroes.length < 3) {
      for (final anime in [...seasonalPopular, ...popular]) {
        if (heroes.length >= 3) break;
        addAnime(
          anime,
          anime.sections.contains('season')
              ? HomeHeroKind.featured
              : HomeHeroKind.popular,
        );
      }
    }
    final updates = seasonal
        .where((anime) => !animeIds.contains(anime.id))
        .toList();
    return HomeFeed(
      heroItems: List.unmodifiable(heroes),
      recentUpdates: updates.isEmpty ? seasonal : List.unmodifiable(updates),
      newAdded: List.unmodifiable(
        newAdded.where((anime) => !animeIds.contains(anime.id)),
      ),
      topics: List.unmodifiable(
        thematicCollections.where(
          (collection) => !collectionIds.contains(collection.id),
        ),
      ),
    );
  }
}
