import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'community_images.dart';
import 'community_widgets.dart';
import 'secondary_page_route.dart';

Future<void> openComments(
  BuildContext context,
  AppStore store,
  String videoId,
  String title, {
  RatingSummary? rating,
  List<Episode> episodes = const [],
  String episodeLabel = '',
}) => Navigator.of(context).push<void>(
  SecondaryPageRoute(
    keepsPlaybackVisible: store.showsPlayer,
    builder: (_) => CommentsPage(
      store: store,
      videoId: videoId,
      title: title,
      rating: rating,
      episodes: episodes,
      episodeLabel: episodeLabel,
    ),
  ),
);

class CommentsPage extends StatefulWidget {
  const CommentsPage({
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
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  final _draft = TextEditingController();
  final _focus = FocusNode();
  final _list = ScrollController();
  final _drafts = <String, (String, OfficialComment?)>{};
  late String _videoId;
  final _comments = <OfficialComment>[];
  final _replies = <String, List<OfficialComment>>{};
  final _replyErrors = <String, Object>{};
  final _loadingReplies = <String>{}, _expanded = <String>{};
  final _voting = <String>{};
  CommentPage? _page;
  int _order = 1, _generation = 0, _nextPage = 0;
  bool _loading = true, _more = false, _sending = false;
  Object? _error, _actionError;
  OfficialComment? _replyTo;
  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _videoId = widget.videoId;
    _load();
  }

  @override
  void didUpdateWidget(covariant CommentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      _changeEpisode(widget.videoId, external: true);
    }
  }

  void _changeEpisode(String videoId, {bool external = false}) {
    if (_videoId == videoId || (_sending && !external)) return;
    _drafts[_videoId] = (_draft.text, _replyTo);
    final draft = _drafts[videoId];
    _focus.unfocus();
    if (_list.hasClients) _list.jumpTo(0);
    setState(() {
      _generation++;
      _videoId = videoId;
      _page = null;
      _comments.clear();
      _replies.clear();
      _replyErrors.clear();
      _loadingReplies.clear();
      _voting.clear();
      _expanded.clear();
      _nextPage = 0;
      _more = false;
      _sending = false;
      _order = 1;
      _error = null;
      _actionError = null;
      _replyTo = draft?.$2;
      _draft.text = draft?.$1 ?? '';
    });
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || _more || _nextPage == 0)) return;
    final generation = more ? _generation : ++_generation;
    final cursor = more ? _nextPage : 0;
    setState(() {
      if (more) {
        _more = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final page = await store.loadComments(
        _videoId,
        order: _order,
        page: cursor,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (!more) {
          _comments.clear();
          _replies.clear();
          _replyErrors.clear();
          _page = page;
        }
        final seen = _comments.map((item) => item.id).toSet();
        _comments.addAll(page.comments.where((item) => seen.add(item.id)));
        _nextPage = page.nextPage == cursor ? 0 : page.nextPage;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _more = false;
        });
      }
    }
  }

  Future<void> _loadReplies(OfficialComment comment) async {
    if (!_loadingReplies.add(comment.id)) return;
    final generation = _generation;
    setState(() => _replyErrors.remove(comment.id));
    try {
      final replies = await store.loadReplies(comment.id);
      if (mounted && generation == _generation) {
        setState(() => _replies[comment.id] = replies);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _replyErrors[comment.id] = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingReplies.remove(comment.id));
      }
    }
  }

  Future<void> _send() async {
    final page = _page;
    if (_sending || _loading || page == null) return;
    final generation = _generation;
    final videoId = _videoId;
    setState(() {
      _sending = true;
      _actionError = null;
    });
    final reply = _replyTo;
    try {
      await store.sendComment(
        videoId: videoId,
        messageId: page.messageId,
        text: _draft.text,
        commentId: reply?.id,
      );
      if (!mounted || generation != _generation) return;
      _draft.clear();
      _drafts.remove(videoId);
      setState(() => _replyTo = null);
      if (reply == null) {
        await _load();
      } else {
        await _loadReplies(reply);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _actionError = error);
      }
    } finally {
      if (mounted && videoId == _videoId) setState(() => _sending = false);
    }
  }

  Future<void> _vote(OfficialComment comment, int type) async {
    if (!_voting.add(comment.id)) return;
    final generation = _generation;
    setState(() => _actionError = null);
    try {
      await store.voteComment(comment, type);
      if (mounted && generation == _generation) await _load();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _actionError = error);
      }
    } finally {
      if (mounted) setState(() => _voting.remove(comment.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => GlassScaffold(
      key: const ValueKey('comments-page'),
      extendBody: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: GlassAppBar(
        leading: GlassIconButton(
          semanticLabel: store.t('close'),
          icon: const Icon(CupertinoIcons.xmark),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          GlassIconButton(
            semanticLabel: store.t('refresh'),
            icon: const Icon(CupertinoIcons.arrow_clockwise),
            onPressed: _loading || _sending ? null : () => _load(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(),
              child: ListView(
                key: const ValueKey('comment-list'),
                controller: _list,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  _header(),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(child: CupertinoActivityIndicator()),
                    ),
                  if (_error != null)
                    CommunityEmpty(
                      icon: CupertinoIcons.wifi_exclamationmark,
                      title: communityError(store, _error),
                      action: CupertinoButton(
                        onPressed: () => _load(more: _comments.isNotEmpty),
                        child: Text(store.t('retry')),
                      ),
                    ),
                  if (!_loading && _comments.isEmpty && _error == null)
                    CommunityEmpty(
                      icon: CupertinoIcons.chat_bubble_2,
                      title: store.t('noComments'),
                      message: store.t('commentHint'),
                    ),
                  if (!_loading)
                    for (final comment in _comments) _thread(comment),
                  if (!_loading && _nextPage != 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: _more
                            ? const CupertinoActivityIndicator()
                            : GlassButton.custom(
                                key: const ValueKey('comments-more'),
                                shape: const LiquidRoundedRectangle(
                                  borderRadius: 22,
                                ),
                                width: 160,
                                height: 44,
                                onTap: () => _load(more: true),
                                child: Text(store.t('loadMore')),
                              ),
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          CommunityComposer(
            store: store,
            controller: _draft,
            hint: store.t(
              _replyTo == null ? 'commentPlaceholder' : 'replyPlaceholder',
            ),
            sending: _sending,
            onSend: _loading || _page == null ? null : _send,
            maximum: 2000,
            focusNode: _focus,
            error: _actionError == null
                ? null
                : communityError(store, _actionError),
            replyName: _replyTo?.name,
            cancelReply: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    ),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          store.t('messageBoard'),
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          widget.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: secondary(context),
            height: 1.5,
          ),
        ),
        if (widget.rating != null) ...[
          const SizedBox(height: 20),
          RatingSummaryCard(rating: widget.rating!),
        ],
        const SizedBox(height: 18),
        Text(
          boardEpisodeLabel(
            store,
            _videoId,
            widget.episodes,
            label: widget.episodeLabel,
          ),
          style: TextStyle(fontSize: 13, color: secondary(context)),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_page != null)
              Text(
                store.t('commentCount').replaceAll('{n}', '${_page!.total}'),
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
            for (final order in [1, 0])
              GlassButton.custom(
                key: ValueKey('comment-order-$order'),
                shape: const LiquidRoundedRectangle(borderRadius: 20),
                width: 108,
                height: 38,
                onTap: () {
                  if (_sending || _order == order) return;
                  setState(() => _order = order);
                  _load();
                },
                child: Text(
                  store.t(order == 1 ? 'recommendedOrder' : 'timeOrder'),
                  style: TextStyle(
                    fontSize: 12,
                    color: _order == order ? brandBlue : secondary(context),
                    fontWeight: _order == order
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _thread(OfficialComment comment) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .04),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            _comment(comment),
            if (_replies[comment.id] case final replies?)
              Padding(
                padding: const EdgeInsets.only(left: 22),
                child: Column(
                  children: [
                    for (final reply in replies)
                      _comment(reply, parent: comment),
                  ],
                ),
              ),
            if (_replyErrors[comment.id] case final error?)
              CupertinoButton(
                onPressed: () => _loadReplies(comment),
                child: Text(
                  communityError(store, error),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _comment(OfficialComment comment, {OfficialComment? parent}) {
    final folded = comment.folded && !_expanded.contains(comment.id);
    return Padding(
      key: ValueKey('comment-${comment.id}'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommentAvatar(url: comment.avatar, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  comment.time,
                  style: TextStyle(color: secondary(context), fontSize: 11),
                ),
                const SizedBox(height: 10),
                if (folded)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(32, 36),
                    onPressed: () => setState(() => _expanded.add(comment.id)),
                    child: Text(
                      store.t('foldedComment'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  )
                else ...[
                  if (comment.text.isNotEmpty)
                    SelectableText(
                      comment.text,
                      style: const TextStyle(fontSize: 14, height: 1.65),
                    ),
                  if (comment.image != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: CommentAttachment(
                        store: store,
                        url: comment.image!,
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 14,
                  runSpacing: 2,
                  children: [
                    _commentAction(
                      CupertinoIcons.arrow_up,
                      '${comment.likes}',
                      store.t('upvote'),
                      comment.vote == 1,
                      _voting.contains(comment.id)
                          ? null
                          : () => _vote(comment, 1),
                    ),
                    _commentAction(
                      CupertinoIcons.arrow_down,
                      '${comment.dislikes}',
                      store.t('downvote'),
                      comment.vote == -1,
                      _voting.contains(comment.id)
                          ? null
                          : () => _vote(comment, 2),
                    ),
                    _commentAction(
                      CupertinoIcons.arrowshape_turn_up_left,
                      store.t('reply'),
                      store.t('reply'),
                      false,
                      () {
                        setState(() {
                          _replyTo = parent ?? comment;
                          _actionError = null;
                        });
                        _focus.requestFocus();
                      },
                    ),
                    if (parent == null && comment.replies > 0)
                      _commentAction(
                        CupertinoIcons.chat_bubble,
                        '${comment.replies}',
                        store.t('viewReplies'),
                        _replies.containsKey(comment.id),
                        _loadingReplies.contains(comment.id)
                            ? null
                            : () => _loadReplies(comment),
                      ),
                  ],
                ),
                if (_loadingReplies.contains(comment.id))
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: CupertinoActivityIndicator(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _commentAction(
    IconData icon,
    String text,
    String label,
    bool active,
    VoidCallback? action,
  ) => Semantics(
    label: label,
    button: true,
    child: CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 8),
      minimumSize: const Size(36, 36),
      onPressed: action,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: active ? brandBlue : secondary(context)),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              color: active ? brandBlue : secondary(context),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _generation++;
    _draft.dispose();
    _focus.dispose();
    _list.dispose();
    super.dispose();
  }
}
