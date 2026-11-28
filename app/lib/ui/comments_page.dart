import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'community_images.dart';
import 'community_widgets.dart';
import 'layout.dart';
import 'secondary_page_route.dart';

Future<void> openComments(
  BuildContext context,
  AppStore store,
  String videoId,
  String title, {
  RatingSummary? rating,
  List<Episode> episodes = const [],
  String episodeLabel = '',
  CommentPage? initialPage,
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
      initialPage: initialPage,
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
    this.initialPage,
    super.key,
  });
  final AppStore store;
  final String videoId, title;
  final RatingSummary? rating;
  final List<Episode> episodes;
  final String episodeLabel;
  final CommentPage? initialPage;

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  static const _autoLoadThreshold = 320.0;
  final _draft = TextEditingController();
  final _focus = FocusNode();
  final _title = GlassLargeTitleController();
  late String _videoId;
  final _comments = <OfficialComment>[];
  final _replies = <String, List<OfficialComment>>{};
  final _repliesVisible = <String>{};
  final _replyErrors = <String, Object>{};
  final _loadingReplies = <String>{};
  final _unfolded = <String>{};
  final _expandedText = <String>{};
  final _voting = <String>{};
  final _visitedCursors = <int>{};
  final _overLimitCache = <(String, int, int, double, bool, Locale?), bool>{};
  CommentPage? _page;
  int _order = 1, _generation = 0, _nextPage = 0;
  int? _loadedOrder;
  bool _loading = true, _refreshing = false, _more = false, _sending = false;
  Object? _error, _moreError, _actionError;
  OfficialComment? _replyThread, _replyTarget;
  String? _lastAccountId;
  bool _suppressDraftSave = false;
  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _videoId = widget.videoId;
    _lastAccountId = store.accountProfile?.id.toLowerCase();
    _restoreDraft(_videoId);
    _draft.addListener(_persistDraft);
    _title.scrollController.addListener(_onScroll);
    store.addListener(_onStoreChanged);
    final initial =
        widget.initialPage ?? store.cachedComments(_videoId, order: _order);
    if (initial != null) {
      _applyInitialPage(initial, order: _order);
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant CommentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      _lastAccountId = store.accountProfile?.id.toLowerCase();
      store.addListener(_onStoreChanged);
    }
    if (oldWidget.videoId != widget.videoId) {
      _persistDraft();
      _switchEpisode(widget.videoId, initialPage: widget.initialPage);
    }
  }

  void _onStoreChanged() {
    if (!mounted) return;
    final accountId = store.accountProfile?.id.toLowerCase();
    if (accountId == _lastAccountId) return;
    _lastAccountId = accountId;
    if (accountId != null &&
        _actionError is CommunityException &&
        (_actionError as CommunityException).needsLogin) {
      setState(() => _actionError = null);
    }
  }

  void _restoreDraft(String videoId) {
    final saved = store.commentDraft(videoId);
    _suppressDraftSave = true;
    _draft.text = saved.text;
    _suppressDraftSave = false;
    _replyThread = saved.replyThread;
    _replyTarget = saved.replyTarget ?? saved.replyThread;
  }

  void _persistDraft() {
    if (_suppressDraftSave) return;
    store.saveCommentDraft(
      _videoId,
      CommentDraft(
        text: _draft.text,
        replyThread: _replyThread,
        replyTarget: _replyTarget,
      ),
    );
  }

  void _applyInitialPage(CommentPage page, {required int order}) {
    _page = page;
    _loadedOrder = order;
    _comments
      ..clear()
      ..addAll(page.comments);
    _visitedCursors.clear();
    _nextPage = page.nextPage;
    _loading = false;
    _refreshing = false;
    _more = false;
    _error = null;
    _moreError = null;
  }

  void _switchEpisode(String videoId, {CommentPage? initialPage}) {
    _focus.unfocus();
    if (_title.scrollController.hasClients) _title.scrollController.jumpTo(0);
    final cached = initialPage ?? store.cachedComments(videoId, order: 1);
    setState(() {
      _generation++;
      _videoId = videoId;
      _page = null;
      _loadedOrder = null;
      _comments.clear();
      _replies.clear();
      _repliesVisible.clear();
      _replyErrors.clear();
      _loadingReplies.clear();
      _voting.clear();
      _unfolded.clear();
      _expandedText.clear();
      _visitedCursors.clear();
      _overLimitCache.clear();
      _nextPage = 0;
      _loading = cached == null;
      _refreshing = false;
      _more = false;
      _sending = false;
      _order = 1;
      _error = null;
      _moreError = null;
      _actionError = null;
      _restoreDraft(videoId);
      if (cached != null) _applyInitialPage(cached, order: 1);
    });
    if (cached == null) _load();
  }

  void _onScroll() {
    if (_loading ||
        _refreshing ||
        _more ||
        _moreError != null ||
        _nextPage == 0 ||
        _loadedOrder != _order ||
        !_title.scrollController.hasClients) {
      return;
    }
    final position = _title.scrollController.position;
    if (position.pixels > 0 &&
        position.maxScrollExtent > 0 &&
        position.pixels >= position.maxScrollExtent - _autoLoadThreshold) {
      _load(more: true);
    }
  }

  Future<void> _load({bool more = false, bool refresh = false}) async {
    if (more) {
      if (_loading ||
          _refreshing ||
          _more ||
          _nextPage == 0 ||
          _loadedOrder != _order) {
        return;
      }
      final generation = _generation;
      final cursor = _nextPage;
      final order = _order;
      setState(() {
        _more = true;
        _moreError = null;
      });
      try {
        final page = await store.loadComments(
          _videoId,
          order: order,
          page: cursor,
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          _visitedCursors.add(cursor);
          final seen = _comments.map((item) => item.id).toSet();
          _comments.addAll(page.comments.where((item) => seen.add(item.id)));
          final next =
              page.comments.isEmpty ||
                  page.nextPage == 0 ||
                  page.nextPage == cursor ||
                  _visitedCursors.contains(page.nextPage)
              ? 0
              : page.nextPage;
          _nextPage = next;
          _page = (_page ?? page).copyWith(total: page.total, nextPage: next);
          _moreError = null;
        });
      } catch (error) {
        if (mounted && generation == _generation) {
          setState(() => _moreError = error);
        }
      } finally {
        if (mounted && generation == _generation) {
          setState(() => _more = false);
        }
      }
      return;
    }

    if (refresh && _sending) return;
    final generation = ++_generation;
    final order = _order;
    final keepExisting =
        refresh && _comments.isNotEmpty && _loadedOrder == order;
    setState(() {
      _loading = !keepExisting;
      _refreshing = keepExisting;
      _more = false;
      _error = null;
      _moreError = null;
      _loadingReplies.clear();
      if (!keepExisting) {
        _comments.clear();
        _replies.clear();
        _repliesVisible.clear();
        _replyErrors.clear();
        _overLimitCache.clear();
        _visitedCursors.clear();
        _nextPage = 0;
        _loadedOrder = null;
      }
    });
    try {
      final page = await store.loadComments(_videoId, order: order, page: 0);
      if (!mounted || generation != _generation) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(page.comments);
        _replies.clear();
        _repliesVisible.clear();
        _replyErrors.clear();
        _loadingReplies.clear();
        _overLimitCache.clear();
        _visitedCursors.clear();
        _page = page;
        _loadedOrder = order;
        _nextPage = page.nextPage;
        _error = null;
        _moreError = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  void _toggleReplies(OfficialComment comment) {
    if (_repliesVisible.contains(comment.id)) {
      setState(() => _repliesVisible.remove(comment.id));
      return;
    }
    if (_replies.containsKey(comment.id)) {
      setState(() {
        _repliesVisible.add(comment.id);
        _replyErrors.remove(comment.id);
      });
      return;
    }
    _loadReplies(comment);
  }

  Future<void> _loadReplies(OfficialComment comment, {bool force = false}) async {
    if (!force && _replies.containsKey(comment.id)) {
      setState(() => _repliesVisible.add(comment.id));
      return;
    }
    if (!_loadingReplies.add(comment.id)) return;
    final generation = _generation;
    setState(() => _replyErrors.remove(comment.id));
    try {
      final replies = await store.loadReplies(comment.id);
      if (mounted && generation == _generation) {
        setState(() {
          _replies[comment.id] = replies;
          _repliesVisible.add(comment.id);
          final index = _comments.indexWhere((item) => item.id == comment.id);
          if (index >= 0 && _comments[index].replies != replies.length) {
            _comments[index] = _comments[index].copyWith(
              replies: replies.length,
            );
            _syncCachedFirstPage();
          }
        });
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

  void _syncCachedFirstPage() {
    final page = _page;
    if (page == null || _loadedOrder != 1) return;
    final cached = store.cachedComments(_videoId, order: 1);
    if (cached == null) return;
    final updatedById = {
      for (final item in _comments) item.id: item,
    };
    var changed = false;
    final nextComments = [
      for (final item in cached.comments)
        if (updatedById[item.id] case final replacement?
            when !identical(replacement, item))
          () {
            changed = true;
            return replacement;
          }()
        else
          item,
    ];
    if (changed) {
      store.updateCachedCommentsPage(
        _videoId,
        cached.copyWith(comments: nextComments),
      );
    }
  }

  void _replaceComment(OfficialComment updated, {String? parentId}) {
    if (parentId == null) {
      final index = _comments.indexWhere((item) => item.id == updated.id);
      if (index >= 0) _comments[index] = updated;
    } else {
      final list = _replies[parentId];
      if (list != null) {
        final index = list.indexWhere((item) => item.id == updated.id);
        if (index >= 0) {
          final next = list.toList(growable: false);
          next[index] = updated;
          _replies[parentId] = next;
        }
      }
    }
    if (_replyThread?.id == updated.id) _replyThread = updated;
    if (_replyTarget?.id == updated.id) _replyTarget = updated;
  }

  Future<void> _send() async {
    final page = _page;
    if (_sending || _loading || page == null || !page.canPost) return;
    final generation = _generation;
    final videoId = _videoId;
    final replyThread = _replyThread;
    setState(() {
      _sending = true;
      _actionError = null;
    });
    try {
      await store.sendComment(
        videoId: videoId,
        messageId: page.messageId,
        text: _draft.text,
        commentId: replyThread?.id,
      );
      if (!mounted || generation != _generation || videoId != _videoId) return;
      _suppressDraftSave = true;
      _draft.clear();
      _suppressDraftSave = false;
      store.clearCommentDraft(videoId);
      _focus.unfocus();
      setState(() {
        _replyThread = null;
        _replyTarget = null;
        if (replyThread != null) {
          final index = _comments.indexWhere(
            (item) => item.id == replyThread.id,
          );
          if (index >= 0) {
            _comments[index] = _comments[index].copyWith(
              replies: _comments[index].replies + 1,
            );
          }
        }
      });
      store.notice = store.t(replyThread == null ? 'commentSent' : 'replySent');
      if (replyThread == null) {
        await _load(refresh: true);
      } else {
        await _loadReplies(replyThread, force: true);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _actionError = error);
      }
    } finally {
      if (mounted && videoId == _videoId) setState(() => _sending = false);
    }
  }

  Future<void> _vote(
    OfficialComment comment,
    int type, {
    OfficialComment? parent,
  }) async {
    if (!_voting.add(comment.id)) return;
    final generation = _generation;
    setState(() => _actionError = null);
    try {
      final updated = await store.voteComment(
        comment,
        type,
        videoId: _videoId,
      );
      if (mounted && generation == _generation) {
        setState(() => _replaceComment(updated, parentId: parent?.id));
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _actionError = error);
      }
    } finally {
      if (mounted) setState(() => _voting.remove(comment.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 780);
    final safe = MediaQuery.paddingOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final textScaler = MediaQuery.textScalerOf(context);
    final composerExtraLeft = math.max(0.0, hPad.left - 20);
    final composerExtraRight = math.max(0.0, hPad.right - 20);
    final composerReserve =
        safe.bottom +
        keyboardInset +
        textScaler.scale(14 * 1.5 * 3).ceilToDouble() +
        64.0 +
        (_replyTarget != null ? textScaler.scale(12) + 28.0 : 0.0) +
        (_actionError != null ? textScaler.scale(12 * 1.5 * 2) + 24.0 : 0.0);
    final showError = _error != null;
    final showEmpty = !_loading && _comments.isEmpty && _error == null;
    final commentCount = _loading ? 0 : _comments.length;
    final showFooter =
        !_loading &&
        _loadedOrder == _order &&
        (_nextPage != 0 || _moreError != null);
    final prefixCount =
        1 +
        (_loading ? 1 : 0) +
        (showError ? 1 : 0) +
        (showEmpty ? 1 : 0);
    final totalCount =
        prefixCount + commentCount + (showFooter ? 1 : 0) + 1;
    final needsLoginAction =
        _actionError is CommunityException &&
        (_actionError as CommunityException).needsLogin;
    return GlassScaffold(
      key: const ValueKey('comments-page'),
      bottomEdgeFade: keyboardInset == 0,
      bottomEdgeFadeExtent: 68.0,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: Text(store.t('messageBoard')),
        largeTitleController: _title,
        padding: layout.appBarPadding(hPad),
        actions: [
          GlassIconButton(
            semanticLabel: store.t('refresh'),
            icon: const Icon(CupertinoIcons.arrow_clockwise),
            onPressed: _loading || _refreshing || _sending
                ? null
                : () => _load(refresh: true),
          ),
          const SizedBox(width: 8),
          GlassIconButton(
            semanticLabel: store.t('close'),
            icon: const Icon(CupertinoIcons.xmark),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      bodyOverlays: [
        Positioned(
          left: composerExtraLeft,
          right: composerExtraRight,
          bottom: keyboardInset,
          child: CommunityComposer(
            store: store,
            controller: _draft,
            hint: store.t(
              _replyThread == null
                  ? 'commentPlaceholder'
                  : 'replyPlaceholder',
            ),
            sending: _sending,
            onSend: _loading || _page == null || !_page!.canPost
                ? null
                : _send,
            maximum: 2000,
            countRunes: true,
            focusNode: _focus,
            error: _actionError == null
                ? null
                : communityError(store, _actionError),
            errorAction: needsLoginAction
                ? _ComposerLoginAction(
                    label: store.t('connectAccount'),
                    onTap: () {
                      _persistDraft();
                      Navigator.pop(context);
                      store.connectAccount();
                    },
                  )
                : null,
            replyName: _replyTarget?.name,
            cancelReply: () {
              setState(() {
                _replyThread = null;
                _replyTarget = null;
              });
              _persistDraft();
            },
          ),
        ),
      ],
      body: SelectionArea(
        child: CustomScrollView(
          key: const ValueKey('comment-list'),
          controller: _title.scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            BahaSliverRefreshControl(
              topInset: safe.top + 44,
              onRefresh: () => _sending
                  ? Future<void>.value()
                  : _load(refresh: true),
            ),
            GlassLargeTitle(
              text: store.t('messageBoard'),
              controller: _title,
              padding: EdgeInsets.fromLTRB(hPad.left, 4, hPad.right, 6),
            ),
            SliverPadding(
              padding: EdgeInsets.only(left: hPad.left, right: hPad.right),
              sliver: SliverList.builder(
                itemCount: totalCount,
                itemBuilder: (context, index) {
                  var cursor = index;
                  if (cursor == 0) return _header();
                  cursor--;
                  if (_loading) {
                    if (cursor == 0) {
                      return const Padding(
                        padding: EdgeInsets.all(30),
                        child: Center(child: CupertinoActivityIndicator()),
                      );
                    }
                    cursor--;
                  }
                  if (showError) {
                    if (cursor == 0) {
                      return CommunityEmpty(
                        icon: CupertinoIcons.wifi_exclamationmark,
                        title: communityError(store, _error),
                        action: GlassActionPill(
                          key: const ValueKey('comments-retry'),
                          label: store.t('retry'),
                          onTap: () => _load(
                            refresh:
                                _comments.isNotEmpty &&
                                _loadedOrder == _order,
                          ),
                        ),
                      );
                    }
                    cursor--;
                  }
                  if (showEmpty) {
                    if (cursor == 0) {
                      return CommunityEmpty(
                        icon: CupertinoIcons.chat_bubble_2,
                        title: store.t('noComments'),
                        message: store.t('commentHint'),
                      );
                    }
                    cursor--;
                  }
                  if (cursor < commentCount) {
                    return _thread(_comments[cursor]);
                  }
                  cursor -= commentCount;
                  if (showFooter && cursor == 0) {
                    return _paginationFooter(context);
                  }
                  return SizedBox(height: composerReserve);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _paginationFooter(BuildContext context) {
    if (_more) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (_moreError != null) {
      return Padding(
        key: const ValueKey('comments-more-error'),
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              communityError(store, _moreError),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondary(context),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            GlassActionPill(
              key: const ValueKey('comments-more-retry'),
              label: store.t('retry'),
              minWidth: 120,
              height: 40,
              onTap: () => _load(more: true),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: GlassActionPill(
          key: const ValueKey('comments-more'),
          label: store.t('loadMore'),
          minWidth: 160,
          height: 44,
          onTap: () => _load(more: true),
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
          RatingSummaryCard(rating: widget.rating!, store: store),
        ],
        const SizedBox(height: 18),
        BoardEpisodePicker(
          store: store,
          videoId: _videoId,
          episodes: widget.episodes,
          fallbackLabel: widget.episodeLabel,
          onSelected: (episode) {
            if (episode.id == _videoId || _sending) return;
            _persistDraft();
            _switchEpisode(episode.id);
          },
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_page != null)
              Text(
                store.t('commentCount').replaceAll('{n}', '${_page!.total}'),
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 236),
              child: BahaSegmentedControl(
                key: const ValueKey('comment-order-control'),
                selectedIndex: _order == 1 ? 0 : 1,
                segments: [
                  GlassSegment(label: store.t('recommendedOrder')),
                  GlassSegment(label: store.t('timeOrder')),
                ],
                onSegmentSelected: (index) {
                  final order = index == 0 ? 1 : 0;
                  if (_sending || _order == order) return;
                  setState(() => _order = order);
                  _load();
                },
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _thread(OfficialComment comment) {
    final visibleReplies = _repliesVisible.contains(comment.id)
        ? _replies[comment.id]
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: DecoratedBox(
        decoration: communityCardDecoration(
          context,
          borderRadius: 26,
          color: Theme.of(context).colorScheme.surface,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              _comment(comment),
              if (visibleReplies != null && visibleReplies.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 22),
                  child: Column(
                    children: [
                      for (final reply in visibleReplies)
                        _comment(reply, parent: comment),
                    ],
                  ),
                ),
              if (_replyErrors[comment.id] case final error?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GlassActionPill(
                    height: 36,
                    fontSize: 12.5,
                    horizontalPadding: 14,
                    label: communityError(store, error),
                    onTap: () => _loadReplies(comment, force: true),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _comment(OfficialComment comment, {OfficialComment? parent}) {
    final folded = comment.folded && !_unfolded.contains(comment.id);
    final repliesOpen = _repliesVisible.contains(comment.id);
    final replyCount = _replies[comment.id]?.length ?? comment.replies;
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
                    onPressed: () => setState(() => _unfolded.add(comment.id)),
                    child: Text(
                      store.t('foldedComment'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  )
                else ...[
                  if (comment.text.isNotEmpty) _commentText(comment),
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
                          : () => _vote(comment, 1, parent: parent),
                    ),
                    _commentAction(
                      CupertinoIcons.arrow_down,
                      '${comment.dislikes}',
                      store.t('downvote'),
                      comment.vote == -1,
                      _voting.contains(comment.id)
                          ? null
                          : () => _vote(comment, 2, parent: parent),
                    ),
                    _commentAction(
                      CupertinoIcons.arrowshape_turn_up_left,
                      store.t('reply'),
                      store.t('reply'),
                      false,
                      () {
                        setState(() {
                          _replyThread = parent ?? comment;
                          _replyTarget = comment;
                          _actionError = null;
                        });
                        _persistDraft();
                        _focus.requestFocus();
                      },
                    ),
                    if (parent == null && replyCount > 0)
                      _commentAction(
                        CupertinoIcons.chat_bubble,
                        '$replyCount',
                        store.t(repliesOpen ? 'hideReplies' : 'viewReplies'),
                        repliesOpen,
                        _loadingReplies.contains(comment.id)
                            ? null
                            : () => _toggleReplies(comment),
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

  Widget _commentText(OfficialComment comment) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final widthKey = (width * 2).round();
      if (_overLimitCache.length >= 256) _overLimitCache.clear();
      final boldText = MediaQuery.boldTextOf(context);
      final textScaler = MediaQuery.textScalerOf(context);
      final locale = Localizations.maybeLocaleOf(context);
      final style = DefaultTextStyle.of(context).style.copyWith(
        fontSize: 14,
        height: 1.65,
        fontWeight: boldText ? FontWeight.bold : null,
      );
      final cacheKey = (
        comment.id,
        comment.text.length,
        widthKey,
        textScaler.scale(14),
        boldText,
        locale,
      );
      final overLimit = _overLimitCache.putIfAbsent(cacheKey, () {
        final painter = TextPainter(
          text: TextSpan(text: comment.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: textScaler,
          locale: locale,
          maxLines: collapsedCommentLines,
          ellipsis: '…',
        )..layout(maxWidth: width);
        final exceeded = painter.didExceedMaxLines;
        painter.dispose();
        return exceeded;
      });
      if (!overLimit) return Text(comment.text, style: style);
      final expanded = _expandedText.contains(comment.id);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expanded)
            Text(comment.text, style: style)
          else
            Text(
              comment.text,
              maxLines: collapsedCommentLines,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(44, 36),
            onPressed: () => setState(() {
              if (expanded) {
                _expandedText.remove(comment.id);
              } else {
                _expandedText.add(comment.id);
              }
            }),
            child: Text(
              store.t(expanded ? 'showLess' : 'showMore'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      );
    },
  );

  Widget _commentAction(
    IconData icon,
    String text,
    String label,
    bool active,
    VoidCallback? action,
  ) => Semantics(
    label: '$label $text',
    button: true,
    enabled: action != null,
    excludeSemantics: true,
    onTap: action,
    child: CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      minimumSize: const Size(44, 44),
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
    _persistDraft();
    store.removeListener(_onStoreChanged);
    _title.scrollController.removeListener(_onScroll);
    _draft.removeListener(_persistDraft);
    _draft.dispose();
    _focus.dispose();
    _title.dispose();
    super.dispose();
  }
}

class _ComposerLoginAction extends StatelessWidget {
  const _ComposerLoginAction({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        key: const ValueKey('composer-login-action'),
        padding: EdgeInsets.zero,
        minimumSize: const Size(36, 32),
        onPressed: onTap,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: brandBlue.withValues(alpha: dark ? .24 : .12),
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                color: dark ? const Color(0xff5eb0ff) : brandBlue,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
