import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'layout.dart';
export 'home_content.dart';

typedef ShowAnime = void Function(Anime anime);
typedef ShowCollection = void Function(AnimeCollection collection);

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


class ContinueCard extends StatelessWidget {
  const ContinueCard({
    required this.store,
    required this.entry,
    this.compact = false,
    this.onOpenDetail,
    super.key,
  });
  final AppStore store;
  final WatchEntry entry;
  final bool compact;
  final VoidCallback? onOpenDetail;

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
    final nextButton = nextVideoId == null
        ? null
        : GlassActionPill(
            key: ValueKey('history-next-${entry.anime.id}'),
            label: store.t('nextEpisode'),
            icon: CupertinoIcons.forward_end_fill,
            height: 44,
            fontSize: 12.5,
            horizontalPadding: 12,
            settings: controlsGlass,
            onTap: () => store.play(
              entry.anime,
              episode: Episode(
                id: nextVideoId,
                label: store.t('nextEpisode'),
              ),
            ),
          );
    final progressText = entry.progress == 1
        ? store.t('historyFinished')
        : entry.progressLabel ?? '';
    return PressableSurface(
      pressedScale: 0.985,
      onTap: onOpenDetail ?? () => store.continueWatching(entry),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: bahaCardDecoration(
          context,
          borderRadius: BahaRadius.card,
          tintAlpha: .055,
          elevated: !compact,
        ),
        child: Row(
          children: [
            ClipRSuperellipse(
              borderRadius: BorderRadius.circular(BahaRadius.thumb),
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
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    compact ? 'EP ${entry.episodeLabel}' : _summary(),
                    maxLines: compact ? 1 : 2,
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
                              Colors.white.withValues(alpha: dark ? .12 : .65),
                              Colors.white.withValues(alpha: dark ? .03 : .12),
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
                      progressText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: secondary(context)),
                    ),
                  ],
                  if (!compact) ...[
                    const SizedBox(height: 8),
                    LayoutBuilder(
                      builder: (context, bounds) {
                        final stackActions =
                            nextButton != null &&
                            (bounds.maxWidth < 210 ||
                                MediaQuery.textScalerOf(context).scale(12) >
                                    15);
                        if (stackActions) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (progressText.isNotEmpty) ...[
                                Text(
                                  progressText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: secondary(context),
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Flexible(child: nextButton),
                                  const SizedBox(width: 8),
                                  playButton,
                                ],
                              ),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                progressText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: secondary(context),
                                ),
                              ),
                            ),
                            if (nextButton != null) ...[
                              const SizedBox(width: 8),
                              nextButton,
                            ],
                            const SizedBox(width: 8),
                            playButton,
                          ],
                        );
                      },
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
  const HistoryContent({required this.store, this.openDetail, super.key});
  final AppStore store;
  final ShowAnime? openDetail;

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
                GlassActionPill(
                  label: store.t(
                    store.hasAccount ? 'retry' : 'connectAccount',
                  ),
                  minWidth: 180,
                  height: 46,
                  onTap: store.hasAccount
                      ? () => store.syncAccount()
                      : store.connectAccount,
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
            itemBuilder: (context, index) {
              final entry = store.history[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: ContinueCard(
                  store: store,
                  entry: entry,
                  onOpenDetail: openDetail == null
                      ? null
                      : () => openDetail!(entry.anime),
                ),
              );
            },
          );
        }
        final columns = constraints.crossAxisExtent >= 1100 ? 3 : 2;
        return SliverMasonryGrid.count(
          key: const ValueKey('history-grid'),
          crossAxisCount: columns,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childCount: store.history.length,
          itemBuilder: (context, index) {
            final entry = store.history[index];
            return ContinueCard(
              store: store,
              entry: entry,
              onOpenDetail: openDetail == null
                  ? null
                  : () => openDetail!(entry.anime),
            );
          },
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
  }) => PressableSurface(
    onTap: () => store.selectTab(2, filter: filter),
    child: ClipRSuperellipse(
      borderRadius: BorderRadius.circular(BahaRadius.tile),
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
    final trimmedFilter = store.libraryQuery.trim();
    final filterBar = BahaSegmentedControl(
      key: const ValueKey('library-filter-control'),
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
                        GlassActionPill(
                          label: store.t(
                            store.hasAccount ? 'retry' : 'connectAccount',
                          ),
                          minWidth: 180,
                          height: 46,
                          onTap: store.hasAccount
                              ? () => store.syncAccount()
                              : connectAccount,
                        ),
                      ],
                    ],
                  ),
                )
              else if (items.isEmpty && trimmedFilter.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      Text(
                        store.t('noResults'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 18),
                      GlassActionPill(
                        key: const ValueKey('library-search-full-catalog'),
                        icon: CupertinoIcons.search,
                        label: store
                            .t('searchFullCatalog')
                            .replaceAll('{query}', trimmedFilter),
                        height: 44,
                        onTap: () => store.openGlobalSearch(trimmedFilter),
                      ),
                    ],
                  ),
                )
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
        if (!needsSync &&
            items.isNotEmpty &&
            store.libraryFilter == 'all' &&
            trimmedFilter.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                store.t('libraryScopeHint'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
            ),
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
        final weekdayControl = BahaSegmentedControl.scrollable(
          key: const ValueKey('schedule-weekday-control'),
          fontSize: 12,
          minHeight: 36,
          labelPadding: EdgeInsets.symmetric(horizontal: wide ? 18 : 11),
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

  Widget _compactRow(BuildContext context, Anime anime) {
    final textScaler = MediaQuery.textScalerOf(context);
    final timeMinWidth = math.max(44.0, textScaler.scale(38.0));
    return PressableSurface(
      pressedScale: 0.985,
      onTap: () => widget.openDetail(anime),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(minWidth: timeMinWidth),
              child: Text(
                anime.updateTime ?? '',
                maxLines: 1,
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
            ),
            const SizedBox(width: 12),
            ClipRSuperellipse(
              borderRadius: BorderRadius.circular(BahaRadius.thumb),
              child: Artwork(anime.cover, width: 88, height: 58),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    anime.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    anime.episodeLabel ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: secondary(context)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabletCard(BuildContext context, Anime anime) => PressableSurface(
    pressedScale: 0.985,
    onTap: () => widget.openDetail(anime),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: bahaCardDecoration(
        context,
        borderRadius: BahaRadius.tile,
        tintAlpha: .055,
      ),
      child: Row(
        children: [
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(BahaRadius.thumb),
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
