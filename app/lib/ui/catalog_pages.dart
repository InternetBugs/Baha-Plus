import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';

typedef ShowAnime = void Function(Anime anime);

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
      crossAxisCount: (constraints.crossAxisExtent / 190).floor().clamp(2, 4),
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
                      width: 310,
                      child: ContinueCard(
                        store: store,
                        entry: store.history[index],
                      ),
                    ),
                  ),
                ),
              ],
              if (store.seasonal.isNotEmpty) ...[
                const SizedBox(height: 28),
                SectionHeading(store.t('seasonal'), onTap: openSeason),
                const SizedBox(height: 16),
                _tiles(store.seasonal.take(8).toList()),
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
    builder: (context, bounds) => ClipRRect(
      borderRadius: BorderRadius.circular(27),
      child: SizedBox(
        height: math.min(bounds.maxWidth * 1.28, 510),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Artwork(anime.artwork),
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
                      ClipRRect(
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
    ),
  );

  Widget _watch(Anime anime) => GlassButton.custom(
    shape: const LiquidRoundedRectangle(borderRadius: 19),
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

  Widget _tiles(List<Anime> items) => Column(
    children: [
      for (var row = 0; row < (items.length + 1) ~/ 2; row++) ...[
        if (row > 0) const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AnimeTile(
                store: store,
                anime: items[row * 2],
                onTap: () => openDetail(items[row * 2]),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: row * 2 + 1 < items.length
                  ? AnimeTile(
                      store: store,
                      anime: items[row * 2 + 1],
                      onTap: () => openDetail(items[row * 2 + 1]),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ],
    ],
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
  final _pages = PageController(viewportFraction: .96);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => SizedBox(
      height: math.min(bounds.maxWidth * 1.28, 510),
      child: PageView.builder(
        key: const PageStorageKey('featured-carousel-pages'),
        controller: _pages,
        padEnds: false,
        allowImplicitScrolling: true,
        physics: const BouncingScrollPhysics(),
        itemCount: widget.items.length,
        itemBuilder: (context, index) => Padding(
          key: ValueKey('featured-${widget.items[index].id}'),
          padding: const EdgeInsets.only(right: 12),
          child: widget.itemBuilder(context, widget.items[index]),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }
}

class ContinueCard extends StatelessWidget {
  const ContinueCard({required this.store, required this.entry, super.key});
  final AppStore store;
  final WatchEntry entry;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final controlsGlass =
        (dark ? LiquidGlassSettings.ios27Dark : LiquidGlassSettings.ios27Light)
            .copyWith(
              bodyMode: GlassBodyMode.clear,
              glassColor: dark
                  ? const Color(0x20ffffff)
                  : const Color(0x55ffffff),
              backerColor: Colors.transparent,
              thickness: 14,
              blur: 3,
              chromaticAberration: .06,
            );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => store.continueWatching(entry),
      child: GlassBackdropGroup(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: secondary(context).withValues(alpha: .06),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Artwork(entry.anime.artwork, width: 60, height: 80),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      entry.anime.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'EP ${entry.episodeLabel}',
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
                    if (entry.progressLabel != null) ...[
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
                  ],
                ),
              ),
              const SizedBox(width: 12),
              GlassIconButton(
                key: ValueKey('history-play-${entry.anime.id}'),
                size: 44,
                useOwnLayer: true,
                quality: GlassQuality.standard,
                settings: controlsGlass,
                semanticLabel: '${store.t('history')} ${entry.anime.title}',
                icon: const Padding(
                  padding: EdgeInsets.only(left: 2),
                  child: Icon(
                    CupertinoIcons.play_fill,
                    color: brandBlue,
                    size: 18,
                  ),
                ),
                onPressed: () => store.continueWatching(entry),
              ),
            ],
          ),
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
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 54),
          child: Column(
            children: [
              if (store.busy)
                const CupertinoActivityIndicator(radius: 16)
              else
                Icon(CupertinoIcons.clock, size: 48, color: secondary(context)),
              const SizedBox(height: 20),
              Text(
                store.busy
                    ? store.t('loading')
                    : store.notice == store.t('accountSyncError')
                    ? store.notice!
                    : store.t(
                        store.accountSynced ? 'noHistory' : 'historyHint',
                      ),
                textAlign: TextAlign.center,
              ),
              if (!store.accountSynced && !store.busy) ...[
                const SizedBox(height: 24),
                GlassButton.custom(
                  shape: const LiquidRoundedRectangle(borderRadius: 22),
                  width: 225,
                  height: 46,
                  onTap: store.connectAccount,
                  child: Text(store.t('connectAccount')),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return SliverList.builder(
      itemCount: store.history.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: ContinueCard(store: store, entry: store.history[index]),
      ),
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
      return SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, index) => AnimeRow(
          store: store,
          anime: items[index],
          onTap: () => openDetail(items[index]),
        ),
      );
    }
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            store.t('recommended'),
            onTap: () => store.selectTab(2, filter: 'hot'),
          ),
          for (final anime in store.popular.take(3))
            AnimeRow(
              store: store,
              anime: anime,
              onTap: () => openDetail(anime),
            ),
          const SizedBox(height: 26),
          SectionHeading(
            store.t('browse'),
            onTap: () => store.selectTab(2, filter: 'all'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _category(
                  store.t('seasonal'),
                  'season',
                  store.seasonal.firstOrNull,
                  Colors.blue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _category(
                  store.t('popular'),
                  'hot',
                  store.popular.firstOrNull,
                  Colors.orange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _category(
                  store.t('allAnime'),
                  'all',
                  store.catalog.items.lastOrNull,
                  Colors.deepPurple,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _category(
                  store.t('favorites'),
                  'favorites',
                  store.favorites.firstOrNull,
                  Colors.green,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _category(String title, String filter, Anime? anime, Color color) =>
      GestureDetector(
        onTap: () => store.selectTab(2, filter: filter),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 116,
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
                      colors: [Colors.transparent, color.withValues(alpha: .9)],
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
    final needsAccount =
        store.libraryFilter == 'favorites' && !store.accountSynced;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              GlassSegmentedControl(
                selectedIndex: const [
                  'all',
                  'season',
                  'hot',
                  'favorites',
                ].indexOf(store.libraryFilter).clamp(0, 3),
                segments: [
                  for (final key in [
                    'all',
                    'seasonFilter',
                    'hotFilter',
                    'favorites',
                  ])
                    GlassSegment(label: store.t(key)),
                ],
                onSegmentSelected: (index) => store.selectTab(
                  2,
                  filter: const ['all', 'season', 'hot', 'favorites'][index],
                ),
              ),
              const SizedBox(height: 22),
              if (needsAccount)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: GlassButton.custom(
                    shape: const LiquidRoundedRectangle(borderRadius: 22),
                    onTap: connectAccount,
                    width: 225,
                    height: 46,
                    child: Text(store.t('connectAccount')),
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
        if (!needsAccount && items.isNotEmpty)
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
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: CupertinoSlidingSegmentedControl<int>(
            groupValue: day,
            children: {
              for (final index in [1, 2, 3, 4, 5, 6, 0])
                index: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Text(
                    days[index],
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            },
            onValueChanged: (value) {
              if (value != null) setState(() => day = value);
            },
          ),
        ),
        const SizedBox(height: 20),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 50),
            child: Text(store.t('noUpdates')),
          ),
        for (final anime in items)
          GestureDetector(
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
                  ClipRRect(
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
                          style: TextStyle(
                            fontSize: 11,
                            color: secondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 24),
        Text(
          store.t('scheduleNote'),
          style: TextStyle(fontSize: 11, color: secondary(context)),
        ),
      ],
    );
  }
}
