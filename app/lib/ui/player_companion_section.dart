import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'comments_preview.dart';
import 'synopsis_section.dart';

class PlayerCompanionSection extends StatelessWidget {
  const PlayerCompanionSection({
    required this.store,
    required this.anime,
    required this.detail,
    required this.playingVideoId,
    required this.episodeLabel,
    required this.maxEpisodeColumns,
    super.key,
  });

  final AppStore store;
  final Anime anime;
  final AnimeDetail? detail;
  final String? playingVideoId;
  final String episodeLabel;
  final int maxEpisodeColumns;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(store.t('episodes')),
        const SizedBox(height: 16),
        if (detail == null)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CupertinoActivityIndicator()),
          )
        else if (detail.episodes.isEmpty)
          Text(
            store.t('detailUnavailable'),
            style: TextStyle(color: secondary(context)),
          )
        else
          _VirtualizedEpisodeGrid(
            store: store,
            anime: anime,
            episodes: detail.episodes,
            playingVideoId: playingVideoId,
            maxEpisodeColumns: maxEpisodeColumns,
          ),
        if (detail != null && detail.description.isNotEmpty) ...[
          const SizedBox(height: 30),
          SynopsisSection(
            store: store,
            title: anime.title,
            description: detail.description,
          ),
        ],
        if (playingVideoId != null) ...[
          const SizedBox(height: 28),
          CompactCommentsPreview(
            key: ValueKey('player-board-$playingVideoId'),
            store: store,
            videoId: playingVideoId!,
            title: anime.title,
            rating: detail?.rating,
            episodes: detail?.episodes ?? const [],
            episodeLabel: episodeLabel,
          ),
        ],
        if (detail != null && detail.metadata.isNotEmpty) ...[
          const SizedBox(height: 22),
          SectionHeading(store.t('metadata')),
          const SizedBox(height: 12),
          for (final item in detail.metadata)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: MediaQuery.textScalerOf(
                      context,
                    ).scale(78.0).clamp(90.0, 140.0),
                    child: Text(
                      item.label,
                      style: TextStyle(color: secondary(context), fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.value,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _VirtualizedEpisodeGrid extends StatefulWidget {
  const _VirtualizedEpisodeGrid({
    required this.store,
    required this.anime,
    required this.episodes,
    required this.playingVideoId,
    required this.maxEpisodeColumns,
  });

  final AppStore store;
  final Anime anime;
  final List<Episode> episodes;
  final String? playingVideoId;
  final int maxEpisodeColumns;

  @override
  State<_VirtualizedEpisodeGrid> createState() =>
      _VirtualizedEpisodeGridState();
}

class _VirtualizedEpisodeGridState extends State<_VirtualizedEpisodeGrid> {
  static const _chipHeight = 40.0;
  static const _spacing = 10.0;
  static const _scrollableThreshold = 60;
  ScrollController? _controller;
  String? _scrolledForVideoId;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _ensureScrollToCurrent(int columns) {
    if (widget.episodes.length <= _scrollableThreshold) return;
    _controller ??= ScrollController();
    final targetId = widget.playingVideoId;
    if (targetId == null || _scrolledForVideoId == targetId) return;
    _scrolledForVideoId = targetId;
    final index = widget.episodes.indexWhere((ep) => ep.id == targetId);
    if (index < columns) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _controller;
      if (!mounted || controller == null || !controller.hasClients) return;
      final row = index ~/ columns;
      final target = math.max(0.0, (row - 1) * (_chipHeight + _spacing));
      final maxExtent = controller.position.maxScrollExtent;
      if (maxExtent > 0) {
        controller.jumpTo(target.clamp(0.0, maxExtent));
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final count = (bounds.maxWidth / 62)
          .floor()
          .clamp(3, widget.maxEpisodeColumns);
      final scrollable = widget.episodes.length > _scrollableThreshold;
      _ensureScrollToCurrent(count);
      final grid = GridView.builder(
        controller: scrollable ? _controller : null,
        shrinkWrap: !scrollable,
        physics: scrollable
            ? const BouncingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: widget.episodes.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count,
          mainAxisSpacing: _spacing,
          crossAxisSpacing: _spacing,
          mainAxisExtent: _chipHeight,
        ),
        itemBuilder: (context, index) {
          final episode = widget.episodes[index];
          final selected = episode.id == widget.playingVideoId;
          return EpisodeChipButton(
            label: episode.label,
            selected: selected,
            onTap: selected
                ? null
                : () => widget.store.play(widget.anime, episode: episode),
          );
        },
      );
      return scrollable ? SizedBox(height: 264, child: grid) : grid;
    },
  );
}
