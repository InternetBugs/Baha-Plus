import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';

typedef ShowAnime = void Function(Anime anime);

class HomeContent extends StatelessWidget {
  const HomeContent({
    required this.store,
    required this.openDetail,
    required this.openHistory,
    super.key,
  });
  final AppStore store;
  final ShowAnime openDetail;
  final VoidCallback openHistory;

  @override
  Widget build(BuildContext context) {
    if (store.catalog.items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (store.seasonal.isNotEmpty) _hero(context, store.seasonal.first),
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
                child: ContinueCard(store: store, entry: store.history[index]),
              ),
            ),
          ),
        ],
        if (store.popular.isNotEmpty) ...[
          const SizedBox(height: 28),
          _compactFeature(store.popular.first),
        ],
        if (store.seasonal.isNotEmpty) ...[
          const SizedBox(height: 28),
          SectionHeading(
            store.t('seasonal'),
            onTap: () => store.selectTab(2, filter: 'season'),
          ),
          const SizedBox(height: 16),
          _tiles(store.seasonal.take(8).toList()),
        ],
        if (store.popular.isNotEmpty) ...[
          const SizedBox(height: 28),
          SectionHeading(
            store.t('popular'),
            onTap: () => store.selectTab(2, filter: 'hot'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 274,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: math.min(store.popular.length, 12),
              separatorBuilder: (_, index) => const SizedBox(width: 16),
              itemBuilder: (_, index) {
                final anime = store.popular[index];
                return SizedBox(
                  width: 138,
                  child: AnimeTile(
                    store: store,
                    anime: anime,
                    poster: true,
                    onTap: () => openDetail(anime),
                  ),
                );
              },
            ),
          ),
        ],
        CatalogFooter(store),
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
            Artwork(anime.cover),
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
                    store.t('featured'),
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

  Widget _compactFeature(Anime anime) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: SizedBox(
      height: 165,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Artwork(anime.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xcc000000)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => openDetail(anime),
                      child: Text(
                        anime.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  _watch(anime),
                ],
              ),
            ),
          ),
        ],
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

class ContinueCard extends StatelessWidget {
  const ContinueCard({required this.store, required this.entry, super.key});
  final AppStore store;
  final WatchEntry entry;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => store.continueWatching(entry),
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
                  LinearProgressIndicator(value: entry.progress, minHeight: 3),
                ],
                if (entry.progressLabel != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    entry.progressLabel!,
                    maxLines: 1,
                    style: TextStyle(fontSize: 10, color: secondary(context)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Icon(CupertinoIcons.play_circle_fill, color: brandBlue),
        ],
      ),
    ),
  );
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
    if (store.query.isNotEmpty) {
      return Column(
        children: [
          if (store.searchMatches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 50),
              child: Text(
                store.t('noResults'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          for (final anime in store.searchMatches)
            AnimeRow(
              store: store,
              anime: anime,
              onTap: () => openDetail(anime),
            ),
          const SizedBox(height: 20),
          GlassButton.custom(
            shape: const LiquidRoundedRectangle(borderRadius: 22),
            useOwnLayer: true,
            onTap: store.officialSearch,
            height: 44,
            width: 200,
            child: Text(store.t('officialSearch')),
          ),
          CatalogFooter(store),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(
          store.t('recommended'),
          onTap: () => store.selectTab(2, filter: 'hot'),
        ),
        for (final anime in store.popular.take(3))
          AnimeRow(store: store, anime: anime, onTap: () => openDetail(anime)),
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
        CatalogFooter(store),
      ],
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
  Widget build(BuildContext context) => Column(
    children: [
      GlassSegmentedControl(
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
      ),
      const SizedBox(height: 22),
      if (store.libraryFilter == 'favorites' && !store.accountSynced)
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
      else if (store.libraryItems.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Text(store.t('noResults')),
        )
      else
        for (final anime in store.libraryItems)
          AnimeRow(store: store, anime: anime, onTap: () => openDetail(anime)),
      CatalogFooter(store),
    ],
  );
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
        CatalogFooter(store),
      ],
    );
  }
}
