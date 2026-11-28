import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'comments_page.dart';
import 'community_images.dart';
import 'community_widgets.dart';

class CompactCommentsPreview extends StatefulWidget {
  const CompactCommentsPreview({
    required this.store,
    required this.videoId,
    required this.title,
    this.rating,
    this.episodes = const [],
    this.episodeLabel = '',
    super.key,
  });
  final AppStore store;
  final String videoId, title;
  final RatingSummary? rating;
  final List<Episode> episodes;
  final String episodeLabel;

  @override
  State<CompactCommentsPreview> createState() => _CompactCommentsPreviewState();
}

class _CompactCommentsPreviewState extends State<CompactCommentsPreview> {
  static const _textSize = 13.0;
  static const _lineHeight = 1.55;
  final _scroll = ScrollController(keepScrollOffset: false);
  late String _videoId;
  CommentPage? _page;
  Object? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _videoId = widget.videoId;
    widget.store.commentsVersion.addListener(_onCommentsVersionChanged);
    _syncOrLoad();
  }

  @override
  void didUpdateWidget(covariant CompactCommentsPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final storeChanged = oldWidget.store != widget.store;
    final episodeChanged = oldWidget.videoId != widget.videoId;
    if (storeChanged) {
      oldWidget.store.commentsVersion.removeListener(_onCommentsVersionChanged);
      widget.store.commentsVersion.addListener(_onCommentsVersionChanged);
    }
    if (episodeChanged || storeChanged) {
      _videoId = widget.videoId;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _syncOrLoad();
    }
  }

  void _onCommentsVersionChanged() {
    if (!mounted) return;
    final cached = widget.store.cachedComments(_videoId);
    if (cached != null) {
      if (!identical(cached, _page) || _loading || _error != null) {
        _generation++;
        setState(() {
          _page = cached;
          _error = null;
          _loading = false;
        });
      }
    } else {
      _load(keepExisting: _page != null);
    }
  }

  void _syncOrLoad() {
    final cached = widget.store.cachedComments(_videoId);
    if (cached != null) {
      _generation++;
      _page = cached;
      _error = null;
      _loading = false;
      return;
    }
    _load();
  }

  Future<void> _load({bool keepExisting = false}) async {
    final generation = ++_generation;
    final videoId = _videoId;
    if (!keepExisting) {
      _page = null;
      _error = null;
      _loading = true;
    }
    if (mounted && !keepExisting) setState(() {});
    try {
      final page = await widget.store.loadComments(videoId);
      if (!mounted || generation != _generation || videoId != _videoId) return;
      setState(() {
        _page = page;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation || videoId != _videoId) return;
      setState(() {
        if (!keepExisting) _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _open() async {
    await openComments(
      context,
      widget.store,
      _videoId,
      widget.title,
      rating: widget.rating,
      episodes: widget.episodes,
      episodeLabel: widget.episodeLabel,
      initialPage: _page,
    );
    if (!mounted) return;
    final cached = widget.store.cachedComments(_videoId);
    if (_error != null && cached != null) {
      setState(() {
        _page = cached;
        _error = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final comments = _page?.comments.take(10).toList() ?? <OfficialComment>[];
    return Column(
      key: const ValueKey('compact-comments-preview'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.rating != null) ...[
          SectionHeading(widget.store.t('ratingTitle')),
          const SizedBox(height: 10),
          RatingSummaryCard(rating: widget.rating!, store: widget.store),
          const SizedBox(height: 28),
        ],
        Semantics(
          button: true,
          child: GestureDetector(
            key: const ValueKey('comments-preview-heading'),
            behavior: HitTestBehavior.opaque,
            onTap: _open,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.store.t('messageBoard'),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_right,
                    color: secondary(context),
                    size: 17,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CupertinoActivityIndicator()),
          )
        else if (_error != null) ...[
          Text(
            communityError(widget.store, _error),
            style: TextStyle(color: secondary(context), height: 1.6),
          ),
          const SizedBox(height: 12),
          GlassActionPill(
            label: widget.store.t('retry'),
            onTap: () => _load(),
          ),
        ] else if (comments.isEmpty) ...[
          Text(
            widget.store.t('noComments'),
            style: TextStyle(color: secondary(context), height: 1.6),
          ),
          _openAll(),
        ] else if (comments.length == 1) ...[
          _comment(context, comments.single),
          _openAll(),
        ] else ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = math.min(constraints.maxWidth * .9, 380.0);
              final cardHeight = _cardHeight(context);
              return SizedBox(
                height: cardHeight + 32,
                child: ListView.separated(
                  key: ValueKey('inline-comments-$_videoId'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  primary: false,
                  padding: const EdgeInsets.only(top: 12, bottom: 20),
                  itemCount: comments.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) => SizedBox(
                    width: cardWidth,
                    child: _comment(context, comments[index]),
                  ),
                ),
              );
            },
          ),
          _openAll(),
        ],
      ],
    );
  }

  double _cardHeight(BuildContext context) =>
      40 +
      (MediaQuery.textScalerOf(context).scale(_textSize) * _lineHeight)
              .ceilToDouble() *
          (1 + collapsedCommentLines);

  Widget _openAll() => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SizedBox(
          width: double.infinity,
          child: GlassActionPill(
            key: const ValueKey('open-full-comments'),
            label: widget.store.t('viewAllRatings'),
            icon: CupertinoIcons.text_bubble,
            trailingIcon: CupertinoIcons.chevron_right,
            height: 48,
            fontSize: 14,
            width: double.infinity,
            onTap: _open,
          ),
        ),
      ),
    ),
  );

  Widget _comment(BuildContext context, OfficialComment comment) {
    final previewText = comment.folded
        ? widget.store.t('foldedComment')
        : comment.text.isNotEmpty
        ? comment.text
        : comment.image != null
        ? widget.store.t('commentImageOnly')
        : '';
    return Semantics(
      button: true,
      child: PressableSurface(
        key: ValueKey('preview-comment-${comment.id}'),
        pressedScale: 0.985,
        onTap: _open,
        child: Container(
          height:
              40 +
              (MediaQuery.textScalerOf(context).scale(_textSize) * _lineHeight)
                      .ceilToDouble() *
                  (1 + collapsedCommentLines),
          decoration: communityCardDecoration(context),
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CommentAvatar(url: comment.avatar),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            comment.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            comment.time,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: secondary(context),
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              previewText,
                              maxLines: collapsedCommentLines,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: secondary(context),
                                height: _lineHeight,
                                fontSize: _textSize,
                              ),
                            ),
                          ),
                          if (!comment.folded && comment.image != null) ...[
                            const SizedBox(width: 8),
                            CommentAttachment(
                              store: widget.store,
                              url: comment.image!,
                              compact: true,
                            ),
                          ],
                        ],
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
  }

  @override
  void dispose() {
    _generation++;
    widget.store.commentsVersion.removeListener(_onCommentsVersionChanged);
    _scroll.dispose();
    super.dispose();
  }
}
