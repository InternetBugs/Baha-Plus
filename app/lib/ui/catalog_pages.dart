import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'layout.dart';

typedef ShowAnime = void Function(Anime anime);

class CatalogStatus extends StatelessWidget {
  const CatalogStatus({
    required this.store,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 20),
    super.key,
  });
  final AppStore store;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: store.catalogFailed
        ? Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  store.t('catalogUnavailable'),
                  style: TextStyle(color: secondary(context), height: 1.6),
                ),
                const SizedBox(height: 12),
                GlassActionPill(
                  label: store.t('retry'),
                  onTap: store.refreshCatalog,
                ),
              ],
            ),
          )
        : store.catalogLoading && store.catalog.items.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CupertinoActivityIndicator()),
          )
        : const SizedBox.shrink(),
  );
}

class AnimeWaterfall extends StatelessWidget {
  const AnimeWaterfall({
    required this.store,
    required this.items,
    required this.openDetail,
    required this.itemKeyPrefix,
    super.key,
  });
  final AppStore store;
  final List<Anime> items;
  final ShowAnime openDetail;
  final String itemKeyPrefix;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) => SliverMasonryGrid.count(
      key: ValueKey('$itemKeyPrefix-waterfall'),
      crossAxisCount: AppLayout.posterColumns(constraints.crossAxisExtent),
      mainAxisSpacing: 24,
      crossAxisSpacing: 16,
      childCount: items.length,
      itemBuilder: (context, index) {
        final anime = items[index];
        return AnimeTile(
          key: ValueKey('$itemKeyPrefix-${anime.id}'),
          store: store,
          anime: anime,
          poster: true,
          titleLines: 3,
          onTap: () => openDetail(anime),
        );
      },
    ),
  );
}

class HomeContent extends StatelessWidget {
  const HomeContent({
    required this.store,
    required this.openDetail,
    required this.openHistory,
    required this.openSeason,
    super.key,
  });
  final AppStore store;
  final ShowAnime openDetail;
  final VoidCallback openHistory;
  final VoidCallback openSeason;

  @override
  Widget build(BuildContext context) {
    if (store.catalog.items.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final popular = store.popular;
    final featured = {
      for (final anime in [
        ...store.seasonal,
        if (popular.isNotEmpty) popular.first,
      ])
        anime.id: anime,
    }.values.toList();
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (featured.isNotEmpty)
                FeaturedCarousel(
                  key: const ValueKey('home-featured-carousel'),
                  items: featured,
                  itemBuilder: _hero,
                ),
              if (store.history.isNotEmpty) ...[
                const SizedBox(height: 24),
                SectionHeading(store.t('history'), onTap: openHistory),
                const SizedBox(height: 12),
                SizedBox(
                  height: 112,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: math.min(store.history.length, 8),
                    separatorBuilder: (_, index) => const SizedBox(width: 12),
                    itemBuilder: (_, index) => SizedBox(
                      width: AppLayout.of(context).isWide ? 340 : 310,
                      child: ContinueCard(
                        store: store,
                        entry: store.history[index],
                        compact: true,
                      ),
                    ),
                  ),
                ),
              ],
              if (store.seasonal.isNotEmpty) ...[
                const SizedBox(height: 28),
                SectionHeading(store.t('seasonal'), onTap: openSeason),
                const SizedBox(height: 16),
                _tiles(store.seasonal),
              ],
              if (popular.isNotEmpty) ...[
                const SizedBox(height: 28),
                SectionHeading(
                  store.t('popular'),
                  onTap: () => store.selectTab(2, filter: 'hot'),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
        if (popular.isNotEmpty)
          AnimeWaterfall(
            store: store,
            items: popular,
            openDetail: openDetail,
            itemKeyPrefix: 'popular',
          ),
      ],
    );
  }

  Widget _hero(BuildContext context, Anime anime) => LayoutBuilder(
    builder: (context, bounds) {
      final wideBanner = bounds.maxWidth > 540;
      final height = bounds.hasBoundedHeight
          ? bounds.maxHeight
          : math.min(bounds.maxWidth * 1.28, 510.0);
      return ClipRSuperellipse(
        borderRadius: BorderRadius.circular(27),
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Artwork(wideBanner ? anime.cover : anime.artwork),
              const ColoredBox(color: Color(0x22000000)),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xdd000000)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      store.t(
                        anime.sections.contains('season')
                            ? 'featured'
                            : 'popular',
                      ),
                      style: const TextStyle(
                        color: Color(0xbbffffff),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => openDetail(anime),
                      child: Semantics(
                        button: true,
                        child: Text(
                          anime.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        ClipRSuperellipse(
                          borderRadius: BorderRadius.circular(11),
                          child: Artwork(anime.artwork, width: 48, height: 48),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                store.t('latestEpisode'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                [anime.episodeLabel, anime.updateTime]
                                    .whereType<String>()
                                    .where((s) => s.isNotEmpty)
                                    .join(' · '),
                                maxLines: 1,
                                style: const TextStyle(
                                  color: Color(0xbbffffff),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        _watch(anime),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _watch(Anime anime) => GlassButton.custom(
    shape: const LiquidRoundedSuperellipse(borderRadius: 19),
    useOwnLayer: true,
    settings: mediaGlass,
    label: store.t('watch'),
    onTap: () => store.play(anime),
    width: 76,
    height: 38,
    child: Text(
      store.t('watch'),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _tiles(List<Anime> allItems) => LayoutBuilder(
    builder: (context, bounds) {
      final columns = AppLayout.landscapeTileColumns(bounds.maxWidth);
      final items = allItems.take(columns == 3 ? 9 : 8).toList();
      final rows = (items.length + columns - 1) ~/ columns;
      return Column(
        children: [
          for (var row = 0; row < rows; row++) ...[
            if (row > 0) const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var col = 0; col < columns; col++) ...[
                  if (col > 0) const SizedBox(width: 16),
                  Expanded(
                    child: row * columns + col < items.length
                        ? AnimeTile(
                            store: store,
                            anime: items[row * columns + col],
                            onTap: () => openDetail(items[row * columns + col]),
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

class FeaturedCarousel extends StatefulWidget {
  const FeaturedCarousel({
    required this.items,
    required this.itemBuilder,
    super.key,
  });
  final List<Anime> items;
  final Widget Function(BuildContext, Anime) itemBuilder;

  @override
  State<FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends State<FeaturedCarousel> {
  PageController? _pages;
  double _fraction = .96;

  PageController _controllerFor(double fraction) {
    if (_pages != null && (_fraction - fraction).abs() < .01) {
      return _pages!;
    }
    final initialPage = _pages != null && _pages!.hasClients
        ? (_pages!.page?.round() ?? _pages!.initialPage)
        : 0;
    final previous = _pages;
    _fraction = fraction;
    _pages = PageController(
      initialPage: initialPage.clamp(0, math.max(0, widget.items.length - 1)),
      viewportFraction: fraction,
    );
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
      final double fraction;
      final double height;
      if (!wide) {
        fraction = .96;
        height = math.min(bounds.maxWidth * 1.28, 510.0);
      } else if (singleWide) {
        fraction = 1.0;
        height = math.min(bounds.maxWidth * .54, 440.0);
      } else if (bounds.maxWidth >= 960) {
        final visible = math.min(3, widget.items.length);
        // Size pages so the trailing card aligns flush with the content grid
        // right edge while preserving the 16px inter-card gap.
        fraction = (bounds.maxWidth + 16.0) / (visible * bounds.maxWidth);
        final cardWidth = bounds.maxWidth * fraction - 16.0;
        height = math.min(cardWidth * 1.28, 480.0);
      } else {
        const targetCardWidth = 350.0;
        fraction = (targetCardWidth / bounds.maxWidth).clamp(.42, .54);
        height = math.min(targetCardWidth * 1.28, 480.0);
      }
      final controller = _controllerFor(fraction);
      return SizedBox(
        height: height,
        child: PageView.builder(
          key: const PageStorageKey('featured-carousel-pages'),
          controller: controller,
          padEnds: false,
          allowImplicitScrolling: true,
          physics: const BouncingScrollPhysics(),
          itemCount: widget.items.length,
          itemBuilder: (context, index) => Padding(
            key: ValueKey('featured-${widget.items[index].id}'),
            padding: EdgeInsets.only(
              right: singleWide ? 0 : (wide ? 16 : 12),
            ),
            child: widget.itemBuilder(context, widget.items[index]),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }
}

class ContinueCard extends StatelessWidget {
  const ContinueCard({
    required this.store,
    required this.entry,
    this.compact = false,
    super.key,
  });
  final AppStore store;
  final WatchEntry entry;
  final bool compact;

  String _summary() {
    final label = entry.episodeLabel.trim();
    final episode = RegExp(r'^\d+(?:\.\d+)?$').hasMatch(label)
        ? store.t('episodeNumber').replaceAll('{n}', label)
        : label;
    final watchedTo = store
        .t('historyWatchedTo')
        .replaceAll('{episode}', episode);
    final watchedAt = entry.watchedAt?.toLocal();
    if (watchedAt == null) return watchedTo;
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final String date;
    if (DateUtils.isSameDay(watchedAt, now)) {
      date = store.t('historyToday');
    } else if (DateUtils.isSameDay(
      watchedAt,
      DateTime(now.year, now.month, now.day - 1),
    )) {
      date = store.t('historyYesterday');
    } else {
      date =
          '${watchedAt.year == now.year ? '' : '${watchedAt.year}/'}'
          '${two(watchedAt.month)}/${two(watchedAt.day)}';
    }
    return '$date ${two(watchedAt.hour)}:${two(watchedAt.minute)} · $watchedTo';
  }

  static final _controlsGlassDark = LiquidGlassSettings.ios27Dark.copyWith(
    bodyMode: GlassBodyMode.clear,
    glassColor: const Color(0x20ffffff),
    backerColor: Colors.transparent,
    thickness: 14,
    blur: 3,
    chromaticAberration: .06,
  );
  static final _controlsGlassLight = LiquidGlassSettings.ios27Light.copyWith(
    bodyMode: GlassBodyMode.clear,
    glassColor: const Color(0x55ffffff),
    backerColor: Colors.transparent,
    thickness: 14,
    blur: 3,
    chromaticAberration: .06,
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final controlsGlass = dark ? _controlsGlassDark : _controlsGlassLight;
    final nextVideoId = entry.nextVideoId;
    final playButton = GlassIconButton(
      key: ValueKey('history-play-${entry.anime.id}'),
      size: 44,
      settings: controlsGlass,
      semanticLabel: '${store.t('history')} ${entry.anime.title}',
      icon: const Padding(
        padding: EdgeInsets.only(left: 2),
        child: Icon(CupertinoIcons.play_fill, color: brandBlue, size: 18),
      ),
      onPressed: () => store.continueWatching(entry),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => store.continueWatching(entry),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: ShapeDecoration(
          color: secondary(context).withValues(alpha: .06),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        child: Row(
          children: [
            ClipRSuperellipse(
              borderRadius: BorderRadius.circular(12),
              child: Artwork(
                entry.anime.artwork,
                width: compact ? 60 : 80,
                height: compact ? 80 : 112,
              ),
            ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      entry.anime.title,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      compact ? 'EP ${entry.episodeLabel}' : _summary(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    ),
                    if (entry.progress != null) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        height: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: dark ? .18 : .7,
                              ),
                              width: .75,
                            ),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.white.withValues(
                                  alpha: dark ? .12 : .65,
                                ),
                                Colors.white.withValues(
                                  alpha: dark ? .03 : .12,
                                ),
                              ],
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(1.5),
                            child: GlassProgressIndicator.linear(
                              value: entry.progress,
                              minWidth: 0,
                              height: 5,
                              color: brandBlue.withValues(alpha: .82),
                              backgroundColor: Colors.transparent,
                              semanticLabel: store.t('playbackProgress'),
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (compact && entry.progressLabel != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        entry.progress == 1
                            ? store.t('historyFinished')
                            : entry.progressLabel!,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 10,
                          color: secondary(context),
                        ),
                      ),
                    ],
                    if (!compact) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.progress == 1
                                  ? store.t('historyFinished')
                                  : entry.progressLabel ?? '',
                              style: TextStyle(
                                fontSize: 12,
                                color: secondary(context),
                              ),
                            ),
                          ),
                          if (nextVideoId != null) ...[
                            GlassButton.custom(
                              key: ValueKey('history-next-${entry.anime.id}'),
                              shape: const LiquidRoundedSuperellipse(
                                borderRadius: 22,
                              ),
                              width: 88,
                              height: 44,
                              settings: controlsGlass,
                              label: store.t('nextEpisode'),
                              onTap: () => store.play(
                                entry.anime,
                                episode: Episode(
                                  id: nextVideoId,
                                  label: store.t('nextEpisode'),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    CupertinoIcons.forward_end_fill,
                                    size: 14,
                                    color: brandBlue,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    store.t('nextEpisode'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: brandBlue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          playButton,
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (compact) ...[const SizedBox(width: 12), playButton],
            ],
          ),
        ),
    );
  }
}

class HistoryContent extends StatelessWidget {
  const HistoryContent({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    if (store.history.isEmpty) {
      final loading = store.busy || store.accountLoading;
      final needsSync = !store.accountSynced || store.accountNeedsRefresh;
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 54),
          child: Column(
            children: [
              if (loading)
                const CupertinoActivityIndicator(radius: 16)
              else
                Icon(CupertinoIcons.clock, size: 48, color: secondary(context)),
              const SizedBox(height: 20),
              Text(
                loading
                    ? store.t('loading')
                    : store.hasAccount && needsSync
                    ? store.t('accountSyncError')
                    : store.notice == store.t('accountSyncError')
                    ? store.notice!
                    : store.t(
                        store.accountSynced ? 'noHistory' : 'historyHint',
                      ),
                textAlign: TextAlign.center,
              ),
              if (needsSync && !loading) ...[
                const SizedBox(height: 24),
                GlassButton.custom(
                  shape: const LiquidRoundedSuperellipse(borderRadius: 23),
                  width: 225,
                  height: 46,
                  onTap: store.hasAccount
                      ? () => store.syncAccount()
                      : store.connectAccount,
                  child: Text(
                    store.t(store.hasAccount ? 'retry' : 'connectAccount'),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        if (constraints.crossAxisExtent < 680) {
          return SliverList.builder(
            itemCount: store.history.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: ContinueCard(store: store, entry: store.history[index]),
            ),
          );
        }
        final columns = constraints.crossAxisExtent >= 1100 ? 3 : 2;
        return SliverMasonryGrid.count(
          key: const ValueKey('history-grid'),
          crossAxisCount: columns,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childCount: store.history.length,
          itemBuilder: (context, index) =>
              ContinueCard(store: store, entry: store.history[index]),
        );
      },
    );
  }
}

class SearchContent extends StatelessWidget {
  const SearchContent({
    required this.store,
    required this.openDetail,
    super.key,
  });
  final AppStore store;
  final ShowAnime openDetail;
  @override
  Widget build(BuildContext context) {
    if (store.query.trim().isNotEmpty) {
      final items = store.searchMatches;
      if (store.searching || store.searchFailed || items.isEmpty) {
        return SliverToBoxAdapter(child: SearchStatus(store: store));
      }
      return SliverLayoutBuilder(
        builder: (context, constraints) {
          if (constraints.crossAxisExtent < 680) {
            return SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, index) => AnimeRow(
                store: store,
                anime: items[index],
                onTap: () => openDetail(items[index]),
              ),
            );
          }
          final columns = constraints.crossAxisExtent >= 1100 ? 3 : 2;
          return SliverMasonryGrid.count(
            key: const ValueKey('search-results-grid'),
            crossAxisCount: columns,
            crossAxisSpacing: 24,
            mainAxisSpacing: 4,
            childCount: items.length,
            itemBuilder: (context, index) => AnimeRow(
              store: store,
              anime: items[index],
              onTap: () => openDetail(items[index]),
            ),
          );
        },
      );
    }
    return SliverToBoxAdapter(
      child: LayoutBuilder(
        builder: (context, bounds) {
          final wide = bounds.maxWidth >= 680;
          final recColumns = bounds.maxWidth >= 1100
              ? 3
              : wide
              ? 2
              : 1;
          final recommended = store.popular
              .take(recColumns == 1 ? 3 : recColumns * 2)
              .toList();
          final categories = [
            _category(
              store.t('seasonal'),
              'season',
              store.seasonal.firstOrNull,
              CupertinoColors.systemBlue,
              height: wide ? 132 : 116,
            ),
            _category(
              store.t('popular'),
              'hot',
              store.popular.firstOrNull,
              CupertinoColors.systemOrange,
              height: wide ? 132 : 116,
            ),
            _category(
              store.t('allAnime'),
              'all',
              store.catalog.items.lastOrNull,
              CupertinoColors.systemIndigo,
              height: wide ? 132 : 116,
            ),
            _category(
              store.t('favorites'),
              'favorites',
              store.favorites.firstOrNull,
              CupertinoColors.systemGreen,
              height: wide ? 132 : 116,
            ),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeading(
                store.t('recommended'),
                onTap: () => store.selectTab(2, filter: 'hot'),
              ),
              if (recColumns == 1)
                for (final anime in recommended)
                  AnimeRow(
                    store: store,
                    anime: anime,
                    onTap: () => openDetail(anime),
                  )
              else
                for (
                  var row = 0;
                  row < (recommended.length + recColumns - 1) ~/ recColumns;
                  row++
                )
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var col = 0; col < recColumns; col++) ...[
                        if (col > 0) const SizedBox(width: 24),
                        Expanded(
                          child: row * recColumns + col < recommended.length
                              ? AnimeRow(
                                  store: store,
                                  anime: recommended[row * recColumns + col],
                                  onTap: () => openDetail(
                                    recommended[row * recColumns + col],
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
              const SizedBox(height: 26),
              SectionHeading(
                store.t('browse'),
                onTap: () => store.selectTab(2, filter: 'all'),
              ),
              const SizedBox(height: 16),
              if (wide)
                Row(
                  children: [
                    for (var index = 0; index < categories.length; index++) ...[
                      if (index > 0) const SizedBox(width: 14),
                      Expanded(child: categories[index]),
                    ],
                  ],
                )
              else ...[
                Row(
                  children: [
                    Expanded(child: categories[0]),
                    const SizedBox(width: 12),
                    Expanded(child: categories[1]),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: categories[2]),
                    const SizedBox(width: 12),
                    Expanded(child: categories[3]),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _category(
    String title,
    String filter,
    Anime? anime,
    Color color, {
    double height = 116,
  }) => GestureDetector(
    onTap: () => store.selectTab(2, filter: filter),
    child: ClipRSuperellipse(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: color),
            if (anime != null) Artwork(anime.cover),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    color.withValues(alpha: .78),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SearchStatus extends StatelessWidget {
  const SearchStatus({required this.store, super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 50),
    child: Center(
      child: store.searching
          ? const CupertinoActivityIndicator()
          : Text(
              store.t(store.searchFailed ? 'searchUnavailable' : 'noResults'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
    ),
  );
}

class LibraryContent extends StatelessWidget {
  const LibraryContent({
    required this.store,
    required this.openDetail,
    required this.connectAccount,
    super.key,
  });
  final AppStore store;
  final ShowAnime openDetail;
  final VoidCallback connectAccount;
  @override
  Widget build(BuildContext context) {
    final items = store.libraryItems;
    final needsSync =
        store.libraryFilter == 'favorites' && !store.accountSynced;
    final filterBar = GlassSegmentedControl(
      selectedIndex: const [
        'all',
        'season',
        'hot',
        'favorites',
      ].indexOf(store.libraryFilter).clamp(0, 3),
      segments: [
        for (final key in ['all', 'seasonFilter', 'hotFilter', 'favorites'])
          GlassSegment(label: store.t(key)),
      ],
      onSegmentSelected: (index) => store.selectTab(
        2,
        filter: const ['all', 'season', 'hot', 'favorites'][index],
      ),
    );
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              if (AppLayout.of(context).isWide)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: filterBar,
                  ),
                )
              else
                filterBar,
              const SizedBox(height: 22),
              if (needsSync)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      if (store.accountLoading)
                        const CupertinoActivityIndicator()
                      else ...[
                        if (store.hasAccount) ...[
                          Text(
                            store.t('accountSyncError'),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                        ],
                        GlassButton.custom(
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 23,
                          ),
                          onTap: store.hasAccount
                              ? () => store.syncAccount()
                              : connectAccount,
                          width: 225,
                          height: 46,
                          child: Text(
                            store.t(
                              store.hasAccount ? 'retry' : 'connectAccount',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              else if (items.isEmpty &&
                  store.query.isNotEmpty &&
                  store.libraryFilter == 'all')
                SearchStatus(store: store)
              else if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(store.t('noResults')),
                ),
            ],
          ),
        ),
        if (!needsSync && items.isNotEmpty)
          AnimeWaterfall(
            store: store,
            items: items,
            openDetail: openDetail,
            itemKeyPrefix: 'library',
          ),
      ],
    );
  }
}

class ScheduleContent extends StatefulWidget {
  const ScheduleContent({
    required this.store,
    required this.openDetail,
    super.key,
  });
  final AppStore store;
  final ShowAnime openDetail;
  @override
  State<ScheduleContent> createState() => _ScheduleContentState();
}

class _ScheduleContentState extends State<ScheduleContent> {
  int day = DateTime.now().toUtc().add(const Duration(hours: 8)).weekday % 7;
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final days = store.simplified
        ? ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
        : ['週日', '週一', '週二', '週三', '週四', '週五', '週六'];
    final items = store.seasonal.where((e) => e.updateDay == day).toList()
      ..sort((a, b) => (a.updateTime ?? '').compareTo(b.updateTime ?? ''));
    return LayoutBuilder(
      builder: (context, bounds) {
        final wide = bounds.maxWidth >= 640;
        final columns = bounds.maxWidth >= 1020
            ? 3
            : wide
            ? 2
            : 1;
        const order = [1, 2, 3, 4, 5, 6, 0];
        final dark = Theme.of(context).brightness == Brightness.dark;
        final textScaler = MediaQuery.textScalerOf(context);
        final controlHeight = (textScaler.scale(13) + 22).clamp(36.0, 56.0);
        final weekdayControl = GlassSegmentedControl.scrollable(
          key: const ValueKey('schedule-weekday-control'),
          height: controlHeight,
          borderRadius: controlHeight / 2,
          maskingQuality: MaskingQuality.off,
          labelPadding: EdgeInsets.symmetric(horizontal: wide ? 18 : 11),
          backgroundColor: dark
              ? const Color(0x1affffff)
              : const Color(0x14000000),
          indicatorColor: dark ? const Color(0x30ffffff) : Colors.white,
          selectedTextStyle: TextStyle(
            fontFamily: 'BahaSans',
            fontFamilyFallback: const ['BahaSansSC'],
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: dark ? Colors.white : brandBlue,
          ),
          unselectedTextStyle: TextStyle(
            fontFamily: 'BahaSans',
            fontFamilyFallback: const ['BahaSansSC'],
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: secondary(context),
          ),
          selectedIndex: order.indexOf(day).clamp(0, order.length - 1),
          segments: [for (final index in order) GlassSegment(label: days[index])],
          onSegmentSelected: (index) => setState(() => day = order[index]),
        );
        return Column(
          children: [
            Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wide ? 560 : bounds.maxWidth,
                ),
                child: weekdayControl,
              ),
            ),
            const SizedBox(height: 20),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 50),
                child: Text(store.t('noUpdates')),
              )
            else if (columns == 1)
              for (final anime in items) _compactRow(context, anime)
            else
              for (
                var row = 0;
                row < (items.length + columns - 1) ~/ columns;
                row++
              ) ...[
                if (row > 0) const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var col = 0; col < columns; col++) ...[
                      if (col > 0) const SizedBox(width: 14),
                      Expanded(
                        child: row * columns + col < items.length
                            ? _tabletCard(context, items[row * columns + col])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ],
            const SizedBox(height: 24),
            Text(
              store.t('scheduleNote'),
              style: TextStyle(fontSize: 11, color: secondary(context)),
            ),
          ],
        );
      },
    );
  }

  Widget _compactRow(BuildContext context, Anime anime) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => widget.openDetail(anime),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              anime.updateTime ?? '',
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ),
          const SizedBox(width: 12),
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(12),
            child: Artwork(anime.cover, width: 88, height: 58),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(anime.title, maxLines: 2),
                const SizedBox(height: 4),
                Text(
                  anime.episodeLabel ?? '',
                  style: TextStyle(fontSize: 11, color: secondary(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _tabletCard(BuildContext context, Anime anime) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => widget.openDetail(anime),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: secondary(context).withValues(alpha: .06),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      child: Row(
        children: [
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(12),
            child: Artwork(anime.cover, width: 104, height: 64),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (anime.updateTime != null && anime.updateTime!.isNotEmpty)
                  Text(
                    anime.updateTime!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: brandBlue,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  anime.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (anime.episodeLabel != null &&
                    anime.episodeLabel!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    anime.episodeLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: secondary(context)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
