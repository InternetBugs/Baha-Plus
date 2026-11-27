import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
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

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 1120);
    final safe = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) => GlassScaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        statusBarStyle: GlassStatusBarStyle.auto,
        appBar: GlassAppBar(
          title: Text(store.t('details'), style: const TextStyle(fontSize: 17)),
          padding: layout.isCompact
              ? const EdgeInsets.symmetric(horizontal: 8)
              : EdgeInsets.only(
                  left: math.max(8.0, hPad.left - 8),
                  right: math.max(8.0, hPad.right - 8),
                ),
          actions: [
            GlassIconButton(
              semanticLabel: store.t('close'),
              icon: const Icon(CupertinoIcons.xmark),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        body: SingleChildScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            hPad.left,
            safe.top + 56,
            hPad.right,
            safe.bottom + 40,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _hero(context, wide: layout.width >= 720),
              if (store.detailLoading)
                const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(child: CupertinoActivityIndicator()),
                ),
              if (store.detailFailed) ...[
                const SizedBox(height: 24),
                Text(
                  store.t('detailUnavailable'),
                  style: TextStyle(color: secondary(context), height: 1.6),
                ),
                const SizedBox(height: 12),
                GlassActionPill(
                  label: store.t('retry'),
                  minWidth: 108,
                  height: 40,
                  onTap: () => store.openDetail(anime),
                ),
              ],
              if (store.detail case final detail?)
                _detailBody(context, detail, split: layout.useSplitDetail),
            ],
          ),
        ),
      ),
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
            Artwork(anime.cover),
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

  Widget _detailBody(
    BuildContext context,
    AnimeDetail detail, {
    required bool split,
  }) {
    final hasPrimary =
        detail.episodes.isNotEmpty || detail.description.isNotEmpty;
    final hasSecondary = detail.metadata.isNotEmpty || detail.rating != null;
    if (split && hasPrimary && hasSecondary) {
      return Padding(
        key: const ValueKey('detail-split-body'),
        padding: const EdgeInsets.only(top: 28),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 60,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (detail.episodes.isNotEmpty)
                    _episodesSection(context, detail.episodes),
                  if (detail.episodes.isNotEmpty &&
                      detail.description.isNotEmpty)
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
                    RatingSummaryCard(rating: detail.rating!),
                    if (detail.metadata.isNotEmpty) const SizedBox(height: 28),
                  ],
                  if (detail.metadata.isNotEmpty)
                    _metadataSection(context, detail.metadata),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detail.episodes.isNotEmpty) ...[
          const SizedBox(height: 28),
          _episodesSection(context, detail.episodes),
        ],
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
          RatingSummaryCard(rating: detail.rating!),
        ],
      ],
    );
  }

  Widget _episodesSection(BuildContext context, List<Episode> episodes) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(store.t('episodes')),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, bounds) {
              final columns = AppLayout.episodeColumns(bounds.maxWidth);
              return Wrap(
                spacing: 10,
                runSpacing: 12,
                children: [
                  for (final episode in episodes)
                    SizedBox(
                      width: (bounds.maxWidth - (columns - 1) * 10) / columns,
                      child: EpisodeChipButton(
                        label: episode.label,
                        onTap: () => _play(context, episode: episode),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      );

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
