import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
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
  late Future<CommentPage> _comments;
  late String _videoId;
  final _scroll = ScrollController(keepScrollOffset: false);

  @override
  void initState() {
    super.initState();
    _videoId = widget.videoId;
    _comments = widget.store.loadComments(_videoId);
  }

  @override
  void didUpdateWidget(covariant CompactCommentsPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.store != widget.store) {
      _videoId = widget.videoId;
      _comments = widget.store.loadComments(_videoId);
    }
  }

  void _open() => openComments(
    context,
    widget.store,
    _videoId,
    widget.title,
    rating: widget.rating,
    episodes: widget.episodes,
    episodeLabel: widget.episodeLabel,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<CommentPage>(
    future: _comments,
    builder: (context, snapshot) {
      final page = snapshot.data;
      final comments = page?.comments.take(10).toList() ?? <OfficialComment>[];
      return Column(
        key: const ValueKey('compact-comments-preview'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          if (widget.rating != null) ...[
            const SizedBox(height: 10),
            RatingSummaryCard(rating: widget.rating!),
          ],
          const SizedBox(height: 16),
          if (snapshot.connectionState == ConnectionState.waiting)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CupertinoActivityIndicator()),
            )
          else if (snapshot.hasError) ...[
            Text(
              communityError(widget.store, snapshot.error),
              style: TextStyle(color: secondary(context), height: 1.6),
            ),
            CupertinoButton(
              onPressed: () => setState(() {
                _comments = widget.store.loadComments(_videoId);
              }),
              child: Text(widget.store.t('retry')),
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
              builder: (context, constraints) => SingleChildScrollView(
                key: ValueKey('inline-comments-$_videoId'),
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                primary: false,
                padding: const EdgeInsets.only(top: 12, bottom: 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final comment in comments)
                      SizedBox(
                        width: constraints.maxWidth * .9,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: _comment(context, comment),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _openAll(),
          ],
        ],
      );
    },
  );

  Widget _openAll() => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: GlassButton.custom(
      key: const ValueKey('open-full-comments'),
      useOwnLayer: true,
      shape: const LiquidRoundedRectangle(borderRadius: 24),
      height: 48,
      width: double.infinity,
      onTap: _open,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(CupertinoIcons.text_bubble, size: 18, color: brandBlue),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              widget.store.t('viewAllRatings'),
              style: const TextStyle(
                color: brandBlue,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(CupertinoIcons.chevron_right, size: 14, color: brandBlue),
        ],
      ),
    ),
  );

  Widget _comment(BuildContext context, OfficialComment comment) => Semantics(
    button: true,
    child: GestureDetector(
      key: ValueKey('preview-comment-${comment.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: _open,
      child: DecoratedBox(
        decoration: communityCardDecoration(context),
        child: Padding(
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
                    if (comment.folded || comment.text.isNotEmpty)
                      Text(
                        comment.folded
                            ? widget.store.t('foldedComment')
                            : comment.text,
                        style: TextStyle(
                          color: secondary(context),
                          height: 1.55,
                          fontSize: 13,
                        ),
                      ),
                    if (!comment.folded && comment.image != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: CommentAttachment(
                          store: widget.store,
                          url: comment.image!,
                          compact: true,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
