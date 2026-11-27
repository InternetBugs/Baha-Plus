import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'catalog_pages.dart' show ContinueCard, ShowAnime, ShowCollection;
import 'chrome.dart';
import 'layout.dart';

class HomeContent extends StatelessWidget {
  const HomeContent({
    required this.store,
    required this.openDetail,
    required this.openHistory,
    required this.openSeason,
    required this.openCollection,
    this.horizontalPadding = EdgeInsets.zero,
    super.key,
  });

  final AppStore store;
  final ShowAnime openDetail;
  final VoidCallback openHistory;
  final VoidCallback openSeason;
  final ShowCollection openCollection;
  final EdgeInsets horizontalPadding;

  String _collectionTitle(AnimeCollection collection) =>
      collection.id == 'expiring-all'
      ? store.t('expiringSoonTitle')
      : collection.title;

  String _formatViews(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final count = int.tryParse(raw);
    if (count == null) return raw;
    if (count >= 10000) {
      final wan = (count / 10000).toStringAsFixed(count >= 100000 ? 0 : 1);
      return '$wan${store.simplified ? '万' : '萬'}';
    }
    return '$count';
  }

  EdgeInsets get _hInset => EdgeInsets.only(
    left: horizontalPadding.left,
    right: horizontalPadding.right,
  );

  @override
  Widget build(BuildContext context) {
    final feed = store.homeFeed;
    final popular = store.popular;
    if (store.catalog.items.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverMainAxisGroup(
      slivers: [
        if (feed.heroItems.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: _hInset,
              child: FeaturedCarousel<HomeHeroItem>(
                key: const ValueKey('home-featured-carousel'),
                items: feed.heroItems,
                keyIdOf: (entry) => entry.keyId,
                itemBuilder: _heroCard,
              ),
            ),
          ),
        if (store.history.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: _ContinueWatchingSection(
                store: store,
                openHistory: openHistory,
                openDetail: openDetail,
                horizontalPadding: _hInset,
              ),
            ),
          ),
        if (feed.recentUpdates.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: _hInset.copyWith(top: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeading(store.t('recentUpdates'), onTap: openSeason),
                  const SizedBox(height: 16),
                  _RecentUpdatesGrid(
                    store: store,
                    items: feed.recentUpdates,
                    openDetail: openDetail,
                  ),
                ],
              ),
            ),
          ),
        if (feed.newAdded.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: _hInset,
                    child: SectionHeading(
                      store.t('newlyAdded'),
                      onTap: () => openCollection(
                        AnimeCollection(
                          id: 'new-added',
                          title: store.t('newlyAdded'),
                          items: store.newAdded,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _NewAddedPosterRail(
                    items: feed.newAdded,
                    openDetail: openDetail,
                    horizontalPadding: _hInset,
                  ),
                ],
              ),
            ),
          ),
        if (feed.topics.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: _hInset,
                    child: SectionHeading(store.t('curatedCollections')),
                  ),
                  const SizedBox(height: 14),
                  _TopicsRail(
                    store: store,
                    collections: feed.topics,
                    titleFor: _collectionTitle,
                    openCollection: openCollection,
                    horizontalPadding: _hInset,
                  ),
                ],
              ),
            ),
          ),
        if (popular.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: _hInset.copyWith(top: 28),
              child: _PopularLibraryCard(store: store, popular: popular),
            ),
          ),
      ],
    );
  }

  Widget _heroCard(BuildContext context, HomeHeroItem entry) => switch (entry) {
    HomeHeroAnime() => _buildAnimeHero(entry),
    HomeHeroCollection() => _buildCollectionHero(entry),
  };

  Widget _buildAnimeHero(HomeHeroAnime entry) {
    final anime = entry.anime;
    final views = _formatViews(anime.views);
    final (badge, dotColor) = switch (entry.kind) {
      HomeHeroKind.seasonalTop => (store.t('heroSeasonalTop'), brandBlue),
      HomeHeroKind.newRelease => (
        store.t('heroNewRelease'),
        CupertinoColors.systemGreen,
      ),
      HomeHeroKind.popular => (
        store.t('popular'),
        CupertinoColors.systemOrange,
      ),
      _ => (store.t('featured'), brandBlue),
    };
    final isNewRelease = entry.kind == HomeHeroKind.newRelease;
    final metaTitle = isNewRelease
        ? (anime.addedDate != null
              ? store.t('addedOnDate').replaceAll('{date}', anime.addedDate!)
              : store.t('latestEpisode'))
        : [
            store.t('latestEpisode'),
            anime.episodeLabel,
          ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final metaSubtitle = [
      if (isNewRelease) anime.episodeLabel else anime.updateTime ?? anime.year,
      if (views.isNotEmpty) views,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

    return _HeroCardShell(
      artworkUrl: (wideBanner) => wideBanner ? anime.cover : anime.artwork,
      badge: badge,
      dotColor: dotColor,
      title: anime.title,
      metaTitle: metaTitle,
      metaSubtitle: metaSubtitle,
      ctaLabel: store.t('watch'),
      onTapCard: () => openDetail(anime),
      onTapCta: () => store.play(anime),
      footerLeading: (wideBanner) => ClipRSuperellipse(
        borderRadius: BorderRadius.circular(11),
        child: Artwork(
          wideBanner ? anime.cover : anime.artwork,
          width: 46,
          height: 46,
        ),
      ),
    );
  }

  Widget _buildCollectionHero(HomeHeroCollection entry) {
    final collection = entry.collection;
    final lead = collection.items.first;
    final expiring = collection.expiring;
    final count = store
        .t('collectionCount')
        .replaceAll('{n}', '${collection.items.length}');
    final badge =
        '${store.t(expiring ? 'heroExpiring' : 'heroCollection')} · $count';
    final previewTitles = collection.items
        .take(2)
        .map((item) => item.title)
        .join('、');
    final previewLine = collection.items.length > 2
        ? store
              .t('collectionPreview')
              .replaceAll('{titles}', previewTitles)
              .replaceAll('{n}', '${collection.items.length}')
        : previewTitles;

    return _HeroCardShell(
      artworkUrl: (_) => lead.artwork,
      badge: badge,
      dotColor: expiring
          ? CupertinoColors.systemOrange
          : CupertinoColors.systemPurple,
      tintColor: expiring ? const Color(0x281a0d02) : const Color(0x22080a16),
      scrimEndColor: expiring
          ? const Color(0xe81a0d02)
          : const Color(0xe8090b16),
      title: _collectionTitle(collection),
      titleFontSize: 24,
      metaTitle: previewLine,
      metaSubtitle: count,
      ctaLabel: store.t(expiring ? 'viewAction' : 'exploreAction'),
      onTapCard: () => openCollection(collection),
      onTapCta: () => openCollection(collection),
      footerLeading: (_) => _PosterMiniStack(
        items: collection.items.take(3).toList(),
        borderColor: const Color(0x99ffffff),
      ),
    );
  }
}

class _HeroCardShell extends StatelessWidget {
  const _HeroCardShell({
    required this.artworkUrl,
    required this.badge,
    required this.dotColor,
    required this.title,
    required this.metaTitle,
    required this.metaSubtitle,
    required this.ctaLabel,
    required this.onTapCard,
    required this.onTapCta,
    required this.footerLeading,
    this.tintColor = const Color(0x22000000),
    this.scrimEndColor = const Color(0xe2000000),
    this.titleFontSize = 25,
  });

  final String Function(bool wideBanner) artworkUrl;
  final String badge;
  final Color dotColor;
  final Color tintColor;
  final Color scrimEndColor;
  final String title;
  final double titleFontSize;
  final String metaTitle;
  final String metaSubtitle;
  final String ctaLabel;
  final VoidCallback onTapCard;
  final VoidCallback onTapCta;
  final Widget Function(bool wideBanner) footerLeading;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wideBanner = bounds.maxWidth > 540;
      final textScaler = MediaQuery.textScalerOf(context);
      final largeText = textScaler.scale(16) > 20;
      final height = bounds.hasBoundedHeight
          ? bounds.maxHeight
          : math.min(bounds.maxWidth * 1.06, 420.0);
      return PressableSurface(
        pressedScale: 0.985,
        onTap: onTapCard,
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(BahaRadius.hero),
          child: SizedBox(
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Artwork(artworkUrl(wideBanner)),
                ColoredBox(color: tintColor),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, scrimEndColor],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _HeroKindChip(label: badge, dotColor: dotColor),
                      const Spacer(),
                      Flexible(
                        flex: 0,
                        child: Semantics(
                          button: true,
                          child: Text(
                            title,
                            maxLines: largeText ? 2 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: titleFontSize,
                              fontWeight: FontWeight.w800,
                              height: 1.24,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          footerLeading(wideBanner),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  metaTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (metaSubtitle.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    metaSubtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xc4ffffff),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          GlassActionPill(
                            useOwnLayer: true,
                            settings: mediaGlass,
                            foregroundColor: Colors.white,
                            label: ctaLabel,
                            onTap: onTapCta,
                            minWidth: 74,
                            height: 38,
                            horizontalPadding: 14,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _HeroKindChip extends StatelessWidget {
  const _HeroKindChip({required this.label, required this.dotColor});

  final String label;
  final Color dotColor;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      color: const Color(0x66000000),
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0x38ffffff), width: 0.75),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ContinueWatchingSection extends StatelessWidget {
  const _ContinueWatchingSection({
    required this.store,
    required this.openHistory,
    required this.openDetail,
    required this.horizontalPadding,
  });

  final AppStore store;
  final VoidCallback openHistory;
  final ShowAnime openDetail;
  final EdgeInsets horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final cardWidth = AppLayout.of(context).isWide ? 340.0 : 310.0;
    final textScaler = MediaQuery.textScalerOf(context);
    final rowHeight = math.max(
      122.0,
      46.0 +
          textScaler.scale(16 * 1.35) +
          textScaler.scale(12 * 1.35) +
          textScaler.scale(10 * 1.35) +
          28.0,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: horizontalPadding,
          child: SectionHeading(store.t('history'), onTap: openHistory),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: rowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: horizontalPadding.copyWith(top: 2, bottom: 10),
            itemCount: math.min(store.history.length, 8),
            separatorBuilder: (_, index) => const SizedBox(width: 12),
            itemBuilder: (_, index) {
              final entry = store.history[index];
              return SizedBox(
                width: cardWidth,
                child: ContinueCard(
                  store: store,
                  entry: entry,
                  compact: true,
                  onOpenDetail: () => openDetail(entry.anime),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RecentUpdatesGrid extends StatelessWidget {
  const _RecentUpdatesGrid({
    required this.store,
    required this.items,
    required this.openDetail,
  });

  final AppStore store;
  final List<Anime> items;
  final ShowAnime openDetail;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final columns = AppLayout.landscapeTileColumns(bounds.maxWidth);
      final count = columns == 4 ? 8 : 6;
      final visible = items.take(count).toList();
      final rows = (visible.length + columns - 1) ~/ columns;
      return Column(
        children: [
          for (var row = 0; row < rows; row++) ...[
            if (row > 0) const SizedBox(height: 22),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var col = 0; col < columns; col++) ...[
                  if (col > 0) const SizedBox(width: 16),
                  Expanded(
                    child: row * columns + col < visible.length
                        ? AnimeTile(
                            key: ValueKey(
                              'recent-${visible[row * columns + col].id}',
                            ),
                            store: store,
                            anime: visible[row * columns + col],
                            showUpdateTime: true,
                            onTap: () =>
                                openDetail(visible[row * columns + col]),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ],
        ],
      );
    },
  );
}

class _NewAddedPosterRail extends StatelessWidget {
  const _NewAddedPosterRail({
    required this.items,
    required this.openDetail,
    required this.horizontalPadding,
  });

  final List<Anime> items;
  final ShowAnime openDetail;
  final EdgeInsets horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final wide = AppLayout.of(context).isWide;
    final cardWidth = wide ? 136.0 : 120.0;
    final posterHeight = cardWidth / 0.72;
    final textScaler = MediaQuery.textScalerOf(context);
    final textHeight =
        textScaler.scale(13.5 * 1.38 * 2 + 11 * 1.35) + 18.0;
    return SizedBox(
      height: posterHeight + textHeight,
      child: ListView.separated(
        key: const ValueKey('home-new-added-rail'),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: horizontalPadding,
        itemCount: math.min(items.length, 12),
        separatorBuilder: (_, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final anime = items[index];
          return SizedBox(
            width: cardWidth,
            child: PressableSurface(
              onTap: () => openDetail(anime),
              child: Semantics(
                button: true,
                label: anime.title,
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: cardWidth,
                      height: posterHeight,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRSuperellipse(
                            borderRadius: BorderRadius.circular(BahaRadius.tile),
                            child: Artwork(anime.artwork),
                          ),
                          if (anime.addedDate != null)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: DecoratedBox(
                                decoration: ShapeDecoration(
                                  color: const Color(0x88000000),
                                  shape: RoundedSuperellipseBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    side: const BorderSide(
                                      color: Color(0x28ffffff),
                                      width: 0.5,
                                    ),
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  child: Text(
                                    anime.addedDate!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      anime.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      anime.episodeLabel ?? anime.year ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: secondary(context)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TopicsRail extends StatelessWidget {
  const _TopicsRail({
    required this.store,
    required this.collections,
    required this.titleFor,
    required this.openCollection,
    required this.horizontalPadding,
  });

  final AppStore store;
  final List<AnimeCollection> collections;
  final String Function(AnimeCollection) titleFor;
  final ShowCollection openCollection;
  final EdgeInsets horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final cardWidth = AppLayout.of(context).isWide ? 248.0 : 224.0;
    final textScaler = MediaQuery.textScalerOf(context);
    final railHeight = math.max(
      116.0,
      36.0 + textScaler.scale(11 * 1.35 + 14.5 * 1.35 * 2) + 20.0,
    );
    return SizedBox(
      height: railHeight,
      child: ListView.separated(
        key: const ValueKey('home-topics-rail'),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: horizontalPadding,
        itemCount: collections.length,
        separatorBuilder: (_, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final collection = collections[index];
          final lead = collection.items.first;
          final count = store
              .t('collectionCount')
              .replaceAll('{n}', '${collection.items.length}');
          return SizedBox(
            width: cardWidth,
            child: PressableSurface(
              key: ValueKey('home-topic-${collection.id}'),
              onTap: () => openCollection(collection),
              child: ClipRSuperellipse(
                borderRadius: BorderRadius.circular(BahaRadius.card),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Artwork(lead.artwork),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: collection.expiring
                              ? const [Color(0x55281604), Color(0xe4221002)]
                              : const [Color(0x4c0a0c14), Color(0xe40a0c14)],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            collection.expiring
                                ? '${store.t('heroExpiring')} · $count'
                                : '${store.t('heroCollection')} · $count',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: collection.expiring
                                  ? const Color(0xffffd080)
                                  : const Color(0xccffffff),
                            ),
                          ),
                          Text(
                            titleFor(collection),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PopularLibraryCard extends StatelessWidget {
  const _PopularLibraryCard({required this.store, required this.popular});

  final AppStore store;
  final List<Anime> popular;

  @override
  Widget build(BuildContext context) {
    final preview = popular.take(3).map((item) => item.title).join('、');
    final hint = store
        .t('popularEntryHint')
        .replaceAll('{n}', '${popular.length}');
    return PressableSurface(
      key: const ValueKey('home-popular-entry'),
      pressedScale: 0.985,
      onTap: () => store.selectTab(2, filter: 'hot'),
      child: Semantics(
        button: true,
        label: store.t('popular'),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: bahaCardDecoration(
            context,
            borderRadius: BahaRadius.card,
          ),
          child: Row(
            children: [
              _PosterMiniStack(
                items: popular.take(3).toList(),
                borderColor: Theme.of(context).scaffoldBackgroundColor,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      store.t('popular'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: brandBlue,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                CupertinoIcons.chevron_right,
                size: 17,
                color: secondary(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PosterMiniStack extends StatelessWidget {
  const _PosterMiniStack({required this.items, required this.borderColor});

  final List<Anime> items;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final visible = items.take(3).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    const cardWidth = 34.0;
    const cardHeight = 46.0;
    const step = 18.0;
    final totalWidth = cardWidth + (visible.length - 1) * step;
    return SizedBox(
      width: totalWidth,
      height: cardHeight,
      child: Stack(
        children: [
          for (var index = visible.length - 1; index >= 0; index--)
            Positioned(
              left: index * step,
              top: 0,
              child: Container(
                width: cardWidth,
                height: cardHeight,
                decoration: ShapeDecoration(
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: borderColor, width: 1.5),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: ClipRSuperellipse(
                  borderRadius: BorderRadius.circular(7),
                  child: Artwork(
                    visible[index].artwork,
                    width: cardWidth,
                    height: cardHeight,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class FeaturedCarousel<T> extends StatefulWidget {
  const FeaturedCarousel({
    required this.items,
    required this.keyIdOf,
    required this.itemBuilder,
    super.key,
  });

  final List<T> items;
  final String Function(T) keyIdOf;
  final Widget Function(BuildContext, T) itemBuilder;

  @override
  State<FeaturedCarousel<T>> createState() => _FeaturedCarouselState<T>();
}

class _FeaturedCarouselState<T> extends State<FeaturedCarousel<T>> {
  final ValueNotifier<int> _currentPage = ValueNotifier<int>(0);
  PageController? _pages;
  double _fraction = .96;

  @override
  void didUpdateWidget(covariant FeaturedCarousel<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final maxIndex = math.max(0, widget.items.length - 1);
    if (_currentPage.value > maxIndex) {
      _currentPage.value = maxIndex;
    }
  }

  PageController _controllerFor(double fraction) {
    if (_pages != null && (_fraction - fraction).abs() < .01) {
      return _pages!;
    }
    final initialPage = _pages != null && _pages!.hasClients
        ? (_pages!.page?.round() ?? _pages!.initialPage)
        : _currentPage.value;
    final previous = _pages;
    _fraction = fraction;
    final clamped = initialPage
        .clamp(0, math.max(0, widget.items.length - 1))
        .toInt();
    _currentPage.value = clamped;
    _pages = PageController(initialPage: clamped, viewportFraction: fraction);
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    return _pages!;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wide = bounds.maxWidth >= 560;
      final singleWide = wide && widget.items.length == 1;
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      final textScaler = MediaQuery.textScalerOf(context);
      final extraTextHeight = math.max(0.0, textScaler.scale(16) - 16) * 4.5;
      final double fraction;
      final double height;
      final int visibleCount;
      if (!wide) {
        fraction = .95;
        height = math.min(bounds.maxWidth * 1.06 + extraTextHeight, 440.0);
        visibleCount = 1;
      } else if (singleWide) {
        fraction = 1.0;
        height = math.min(bounds.maxWidth * .50 + extraTextHeight, 440.0);
        visibleCount = 1;
      } else if (bounds.maxWidth >= 960) {
        visibleCount = math.min(3, widget.items.length);
        // Size pages so the trailing card aligns flush with the content grid
        // right edge while preserving the 16px inter-card gap.
        fraction = (bounds.maxWidth + 16.0) / (visibleCount * bounds.maxWidth);
        final cardWidth = bounds.maxWidth * fraction - 16.0;
        height = math.min(cardWidth * 1.18 + extraTextHeight, 460.0);
      } else {
        const targetCardWidth = 350.0;
        fraction = (targetCardWidth / bounds.maxWidth).clamp(.42, .54);
        height = math.min(targetCardWidth * 1.18 + extraTextHeight, 460.0);
        visibleCount = (1 / fraction).floor().clamp(1, widget.items.length);
      }
      final controller = _controllerFor(fraction);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: height,
            child: PageView.builder(
              key: const PageStorageKey('featured-carousel-pages'),
              controller: controller,
              clipBehavior: Clip.none,
              padEnds: false,
              allowImplicitScrolling: true,
              physics: const BouncingScrollPhysics(),
              itemCount: widget.items.length,
              onPageChanged: (index) => _currentPage.value = index,
              itemBuilder: (context, index) => Padding(
                key: ValueKey('featured-${widget.keyIdOf(widget.items[index])}'),
                padding: EdgeInsets.only(
                  right: singleWide ? 0 : (wide ? 16 : 12),
                ),
                child: widget.itemBuilder(context, widget.items[index]),
              ),
            ),
          ),
          if (widget.items.length > visibleCount) ...[
            const SizedBox(height: 12),
            ValueListenableBuilder<int>(
              valueListenable: _currentPage,
              builder: (context, page, _) {
                final activeIndex = page
                    .clamp(0, math.max(0, widget.items.length - 1))
                    .toInt();
                return Row(
                  key: const ValueKey('featured-carousel-indicators'),
                  children: [
                    for (
                      var index = 0;
                      index < widget.items.length;
                      index++
                    ) ...[
                      if (index > 0) const SizedBox(width: 6),
                      AnimatedContainer(
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        width: index == activeIndex ? 20 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: index == activeIndex
                              ? brandBlue
                              : secondary(context).withValues(alpha: .32),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      );
    },
  );

  @override
  void dispose() {
    _currentPage.dispose();
    _pages?.dispose();
    super.dispose();
  }
}
