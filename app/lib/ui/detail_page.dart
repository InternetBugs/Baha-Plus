import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'comments_page.dart';
import 'community_widgets.dart';
import 'layout.dart';
import 'synopsis_section.dart';

class DetailPage extends StatelessWidget {
  const DetailPage({required this.store, required this.anime, super.key});
  final AppStore store;
  final Anime anime;

  void _play(BuildContext context, {Episode? episode}) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    store.play(anime, episode: episode);
  }

  WatchEntry? _watchEntry() {
    for (final entry in store.history) {
      if (entry.anime.id == anime.id) return entry;
    }
    return null;
  }

  String? _commentVideoId(AnimeDetail detail) {
    final watched = _watchEntry()?.videoId;
    if (watched != null && detail.episodes.any((e) => e.id == watched)) {
      return watched;
    }
    if (anime.latestVideoId != null && anime.latestVideoId!.isNotEmpty) {
      return anime.latestVideoId;
    }
    return detail.episodes.isNotEmpty ? detail.episodes.last.id : null;
  }

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 1120);
    final safe = MediaQuery.paddingOf(context);
    final split = layout.useSplitDetail;
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) {
        final detail = store.detail;
        final watched = _watchEntry();
        final watchedVideoId = watched?.videoId;
        final canSplit =
            split &&
            detail != null &&
            (detail.episodes.isNotEmpty || detail.description.isNotEmpty) &&
            (detail.metadata.isNotEmpty || detail.rating != null);

        return GlassScaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          statusBarStyle: GlassStatusBarStyle.auto,
          appBar: GlassAppBar(
            title: Text(
              store.t('details'),
              style: const TextStyle(fontSize: 17),
            ),
            padding: layout.appBarPadding(hPad),
            actions: [
              GlassIconButton(
                semanticLabel: store.t('close'),
                icon: const Icon(CupertinoIcons.xmark),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              BahaSliverRefreshControl(
                topInset: safe.top + 44,
                onRefresh: () => store.openDetail(anime),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  hPad.left,
                  safe.top + 56,
                  hPad.right,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: _hero(context, wide: layout.width >= 720),
                ),
              ),
              if (store.detailLoading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                ),
              if (store.detailFailed)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(hPad.left, 24, hPad.right, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          store.t('detailUnavailable'),
                          style: TextStyle(
                            color: secondary(context),
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 12),
                        GlassActionPill(
                          label: store.t('retry'),
                          minWidth: 108,
                          height: 40,
                          onTap: () => store.openDetail(anime),
                        ),
                      ],
                    ),
                  ),
                ),
              if (detail != null && canSplit)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    hPad.left,
                    28,
                    hPad.right,
                    safe.bottom + 40,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _splitDetailBody(
                      context,
                      detail,
                      watchedVideoId: watchedVideoId,
                    ),
                  ),
                )
              else if (detail != null) ...[
                if (detail.episodes.isNotEmpty) ...[
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(hPad.left, 28, hPad.right, 14),
                    sliver: SliverToBoxAdapter(
                      child: SectionHeading(store.t('episodes')),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: hPad.left),
                    sliver: _sliverEpisodesGrid(
                      context,
                      detail.episodes,
                      watchedVideoId: watchedVideoId,
                    ),
                  ),
                ],
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    hPad.left,
                    0,
                    hPad.right,
                    safe.bottom + 40,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _stackedDetailTail(context, detail),
                  ),
                ),
              ] else
                SliverToBoxAdapter(child: SizedBox(height: safe.bottom + 40)),
            ],
          ),
        );
      },
    );
  }

  Widget _hero(BuildContext context, {required bool wide}) {
    final textScaler = MediaQuery.textScalerOf(context);
    final showPoster = wide && anime.poster != null;
    final titleFontSize = wide ? 30.0 : 25.0;
    final heroHeight = math.max(
      wide ? 380.0 : 350.0,
      190.0 + textScaler.scale(titleFontSize * 1.3 * 3 + 32.0),
    );
    final playButtonHeight = (textScaler.scale(16) + 26).clamp(48.0, 62.0);
    final info = Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          anime.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: titleFontSize,
            fontWeight: FontWeight.w700,
            height: 1.28,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          [anime.year, anime.episodeLabel].whereType<String>().join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xbbffffff), fontSize: 12),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Flexible(
              child: GlassActionPill(
                useOwnLayer: true,
                settings: mediaGlass,
                foregroundColor: Colors.white,
                icon: CupertinoIcons.play_fill,
                label: store.t(
                  anime.latestVideoId == null ? 'play' : 'playLatest',
                ),
                minWidth: 168,
                height: playButtonHeight,
                fontSize: 16,
                horizontalPadding: 20,
                onTap: () => _play(context),
              ),
            ),
            const SizedBox(width: 14),
            GlassIconButton(
              useOwnLayer: true,
              settings: mediaGlass,
              size: playButtonHeight,
              semanticLabel: store.t(
                store.isFavorite(anime) ? 'unsave' : 'save',
              ),
              icon: Icon(
                store.isFavorite(anime)
                    ? CupertinoIcons.bookmark_fill
                    : CupertinoIcons.bookmark,
                color: Colors.white,
              ),
              onPressed: () => store.toggleFavorite(anime),
            ),
          ],
        ),
      ],
    );
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(BahaRadius.hero),
      child: SizedBox(
        height: heroHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Artwork(anime.cover, minDecodeHeight: heroHeight),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(wide ? 0x33000000 : 0x11000000),
                    const Color(0xdd000000),
                  ],
                ),
              ),
            ),
            if (wide)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0x99000000), Color(0x11000000)],
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.all(wide ? 28 : 24),
              child: showPoster
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(
                                BahaRadius.tile,
                              ),
                            ),
                            shadows: const [
                              BoxShadow(
                                color: Color(0x66000000),
                                blurRadius: 24,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          child: ClipRSuperellipse(
                            borderRadius: BorderRadius.circular(BahaRadius.tile),
                            child: Artwork(
                              anime.poster,
                              width: 170,
                              height: 238,
                            ),
                          ),
                        ),
                        const SizedBox(width: 28),
                        Expanded(child: info),
                      ],
                    )
                  : info,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sliverEpisodesGrid(
    BuildContext context,
    List<Episode> episodes, {
    required String? watchedVideoId,
  }) {
    final textScaler = MediaQuery.textScalerOf(context);
    final chipExtent = (textScaler.scale(13.5) * 1.35 + 24).clamp(44.0, 68.0);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = AppLayout.episodeColumns(constraints.crossAxisExtent);
        return SliverGrid.builder(
          itemCount: episodes.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            mainAxisExtent: chipExtent,
          ),
          itemBuilder: (context, index) {
            final episode = episodes[index];
            return EpisodeChipButton(
              label: episode.label,
              selected: episode.id == watchedVideoId,
              onTap: () => _play(context, episode: episode),
            );
          },
        );
      },
    );
  }

  Widget _splitDetailBody(
    BuildContext context,
    AnimeDetail detail, {
    required String? watchedVideoId,
  }) {
    final commentVideoId = _commentVideoId(detail);
    return Row(
      key: const ValueKey('detail-split-body'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 60,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detail.episodes.isNotEmpty)
                _splitEpisodesSection(
                  context,
                  detail.episodes,
                  watchedVideoId: watchedVideoId,
                ),
              if (detail.episodes.isNotEmpty && detail.description.isNotEmpty)
                const SizedBox(height: 28),
              if (detail.description.isNotEmpty)
                SynopsisSection(
                  store: store,
                  title: anime.title,
                  description: detail.description,
                ),
            ],
          ),
        ),
        const SizedBox(width: 32),
        Expanded(
          flex: 40,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detail.rating != null) ...[
                SectionHeading(store.t('ratingTitle')),
                const SizedBox(height: 10),
                RatingSummaryCard(rating: detail.rating!, store: store),
                if (commentVideoId != null) ...[
                  const SizedBox(height: 14),
                  _openCommentsButton(context, detail, commentVideoId),
                ],
                if (detail.metadata.isNotEmpty) const SizedBox(height: 28),
              ] else if (commentVideoId != null) ...[
                _openCommentsButton(context, detail, commentVideoId),
                if (detail.metadata.isNotEmpty) const SizedBox(height: 24),
              ],
              if (detail.metadata.isNotEmpty)
                _metadataSection(context, detail.metadata),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stackedDetailTail(BuildContext context, AnimeDetail detail) {
    final commentVideoId = _commentVideoId(detail);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detail.description.isNotEmpty) ...[
          const SizedBox(height: 28),
          SynopsisSection(
            store: store,
            title: anime.title,
            description: detail.description,
          ),
        ],
        if (detail.metadata.isNotEmpty) ...[
          const SizedBox(height: 28),
          _metadataSection(context, detail.metadata),
        ],
        if (detail.rating != null) ...[
          const SizedBox(height: 28),
          SectionHeading(store.t('ratingTitle')),
          const SizedBox(height: 10),
          RatingSummaryCard(rating: detail.rating!, store: store),
        ],
        if (commentVideoId != null) ...[
          const SizedBox(height: 16),
          _openCommentsButton(context, detail, commentVideoId),
        ],
      ],
    );
  }

  Widget _openCommentsButton(
    BuildContext context,
    AnimeDetail detail,
    String videoId,
  ) => GlassActionPill(
    key: const ValueKey('detail-open-comments'),
    label: store.t('openComments'),
    icon: CupertinoIcons.chat_bubble_2,
    trailingIcon: CupertinoIcons.chevron_right,
    height: 42,
    fontSize: 13.5,
    onTap: () => openComments(
      context,
      store,
      videoId,
      anime.title,
      rating: detail.rating,
      episodes: detail.episodes,
    ),
  );

  Widget _splitEpisodesSection(
    BuildContext context,
    List<Episode> episodes, {
    required String? watchedVideoId,
  }) {
    final textScaler = MediaQuery.textScalerOf(context);
    final chipExtent = (textScaler.scale(13.5) * 1.35 + 24).clamp(44.0, 68.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(store.t('episodes')),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, bounds) {
            final columns = AppLayout.episodeColumns(bounds.maxWidth);
            final useScrollBox = episodes.length > 60;
            final grid = GridView.builder(
              primary: false,
              shrinkWrap: !useScrollBox,
              physics: useScrollBox
                  ? const BouncingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: episodes.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 10,
                mainAxisSpacing: 12,
                mainAxisExtent: chipExtent,
              ),
              itemBuilder: (context, index) {
                final episode = episodes[index];
                return EpisodeChipButton(
                  label: episode.label,
                  selected: episode.id == watchedVideoId,
                  onTap: () => _play(context, episode: episode),
                );
              },
            );
            return useScrollBox ? SizedBox(height: 360, child: grid) : grid;
          },
        ),
      ],
    );
  }

  Widget _metadataSection(BuildContext context, List<Metadata> items) {
    final labelWidth = MediaQuery.textScalerOf(
      context,
    ).scale(78.0).clamp(90.0, 140.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(store.t('metadata')),
        const SizedBox(height: 12),
        for (final metadata in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    metadata.label,
                    style: TextStyle(color: secondary(context), fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    metadata.value,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
