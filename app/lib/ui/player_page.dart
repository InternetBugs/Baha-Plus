import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart'
    show DragStartBehavior, HorizontalDragGestureRecognizer, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/playback_state.dart';
import '../data/app_store.dart';
import 'buffered_playback_track.dart';
import 'chrome.dart';
import 'comments_preview.dart';
import 'danmaku_panel.dart';
import 'synopsis_section.dart';

/// The complete app playback page. The session-owned video surface is passed
/// in so changing layouts never creates a second official player or session.
class PlayerPage extends StatefulWidget {
  const PlayerPage({required this.store, required this.video, super.key});
  final AppStore store;
  final Widget video;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  AppStore get store => widget.store;
  double? _scrub;
  String? _scrubDocument;
  int _scrubRevision = 0;
  double? _swipeStartPosition;
  double _swipeLastX = 0;
  double _swipeSecondsPerPixel = 0;
  Size? _swipeViewport;
  bool _holdingSpeed = false;
  double? _holdOriginalRate;
  String? _holdDocument;
  Size? _holdViewport;
  Future<void>? _holdStart;
  bool _restoringHoldSpeed = false;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  String _controlState = '';
  Timer? _hideTimer;
  final _videoSurfaceKey = GlobalKey(debugLabel: 'player-video-surface');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_syncFullscreen);
    store.playback.addListener(_playbackChanged);
    _syncFullscreen();
    _playbackChanged();
  }

  void _playbackChanged() {
    final state = store.playback.value;
    if (_holdingSpeed && !_canHoldSpeed) _stopHoldSpeed();
    unawaited(_restoreHoldSpeed());
    if (_scrub != null &&
        (!state.canControl || _scrubDocument != store.operation.id)) {
      _cancelScrub();
    }
    if (store.playerLocked &&
        state.phase != PlaybackPhase.content &&
        state.phase != PlaybackPhase.loading) {
      store.setPlayerLocked(false);
    }
    final key = '${state.phase.name}:${state.paused}';
    if (key == _controlState) return;
    _controlState = key;
    _revealControls();
  }

  void _revealControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    final state = store.playback.value;
    if (_scrub == null &&
        store.playerFullscreen &&
        (store.playerLocked ||
            (state.phase == PlaybackPhase.content && !state.paused))) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _controlsVisible = false);
      });
    }
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (_controlsVisible && mounted) setState(() => _controlsVisible = false);
  }

  void _toggleControls() {
    if (_controlsVisible) {
      _hideControls();
    } else {
      _revealControls();
    }
  }

  void _setLocked(bool locked) {
    store.setPlayerLocked(locked);
    _revealControls();
  }

  void _dismissOutsideVideo(PointerDownEvent event) {
    final surface = _videoSurfaceKey.currentContext?.findRenderObject();
    if (surface is! RenderBox || !surface.hasSize) return;
    final bounds = Offset.zero & surface.size;
    if (!bounds.contains(surface.globalToLocal(event.position))) {
      _hideControls();
    }
  }

  void _syncFullscreen() {
    if (_holdingSpeed &&
        (store.playerLocked ||
            _holdDocument != store.operation.id ||
            _fullscreen != store.playerFullscreen)) {
      _stopHoldSpeed();
    }
    unawaited(_restoreHoldSpeed());
    if (_scrub != null &&
        (store.playerLocked ||
            _scrubDocument != store.operation.id ||
            _fullscreen != store.playerFullscreen)) {
      _cancelScrub();
    }
    if (_fullscreen == store.playerFullscreen) return;
    _fullscreen = store.playerFullscreen;
    _revealControls();
    unawaited(_screenMode(_fullscreen));
  }

  bool get _canSwipeSeek =>
      MediaQuery.orientationOf(context) == Orientation.landscape &&
      !store.playerLocked &&
      store.playback.value.canControl;

  bool get _canHoldSpeed {
    final state = store.playback.value;
    return store.applicationActive &&
        !store.playerLocked &&
        state.canControl &&
        !state.paused &&
        !state.ended &&
        _scrub == null;
  }

  void _startHoldSpeed() {
    if (!_canHoldSpeed || _holdOriginalRate != null) return;
    setState(() {
      _holdingSpeed = true;
      _holdOriginalRate = store.playback.value.rate;
      _holdDocument = store.operation.id;
      _holdViewport = MediaQuery.sizeOf(context);
    });
    _holdStart = store.controlPlayer('rate', 2);
  }

  void _stopHoldSpeed({bool rebuild = true}) {
    if (_holdingSpeed) {
      void stop() {
        _holdingSpeed = false;
        _holdViewport = null;
      }

      if (rebuild && mounted) {
        setState(stop);
      } else {
        stop();
      }
    }
    unawaited(_restoreHoldSpeed());
  }

  Future<void> _restoreHoldSpeed() async {
    if (_holdingSpeed || _holdOriginalRate == null || _restoringHoldSpeed) {
      return;
    }
    _restoringHoldSpeed = true;
    try {
      // A quick release must restore after the initial rate command finishes.
      await _holdStart;
      if (_holdDocument == store.operation.id) {
        // Lifecycle and player transitions can temporarily reject commands.
        // Keep the original rate until this same session can accept it again.
        if (!store.applicationActive || !store.playback.value.canControl) {
          return;
        }
        await store.controlPlayer('rate', _holdOriginalRate);
      }
      _holdOriginalRate = null;
      _holdDocument = null;
      _holdStart = null;
    } finally {
      _restoringHoldSpeed = false;
    }
  }

  void _beginScrub(double position) {
    if (!store.playback.value.canControl || store.playerLocked) return;
    _scrubRevision++;
    setState(() {
      _scrubDocument = store.operation.id;
      _scrub = position.clamp(0.0, store.playback.value.duration);
    });
    _revealControls();
  }

  void _updateScrub(double position) {
    if (_scrub == null) {
      _beginScrub(position);
      return;
    }
    if (_scrubDocument != store.operation.id ||
        !store.playback.value.canControl ||
        store.playerLocked) {
      _cancelScrub();
      return;
    }
    setState(() => _scrub = position.clamp(0.0, store.playback.value.duration));
  }

  Future<void> _commitScrub() async {
    final target = _scrub;
    if (target == null) return;
    if (_scrubDocument != store.operation.id ||
        !store.playback.value.canControl ||
        store.playerLocked) {
      _cancelScrub();
      return;
    }
    final revision = _scrubRevision;
    setState(() {
      _swipeStartPosition = null;
      _swipeViewport = null;
    });
    // Keep both progress displays at the target until the player command has
    // finished. Native seeks publish their new position before completing.
    await store.controlPlayer('seek', target);
    if (!mounted || revision != _scrubRevision) return;
    _cancelScrub();
  }

  void _cancelScrub() {
    if (_scrub == null) return;
    _scrubRevision++;
    setState(() {
      _scrub = null;
      _scrubDocument = null;
      _swipeStartPosition = null;
      _swipeViewport = null;
    });
    _revealControls();
  }

  void _startSwipe(DragStartDetails details) {
    if (!_canSwipeSeek || _scrub != null) return;
    final surface = _videoSurfaceKey.currentContext?.findRenderObject();
    if (surface is! RenderBox || !surface.hasSize || surface.size.width <= 0) {
      return;
    }
    final state = store.playback.value;
    _swipeStartPosition = state.position.clamp(0.0, state.duration);
    _swipeLastX = details.globalPosition.dx;
    _swipeViewport = MediaQuery.sizeOf(context);
    // One video width moves at most two minutes, regardless of episode length.
    // Keep fractional seconds so small reversals can refine the target.
    _swipeSecondsPerPixel =
        state.duration.clamp(0.0, 120.0) / surface.size.width;
    _beginScrub(_swipeStartPosition!);
  }

  void _updateSwipe(DragUpdateDetails details) {
    if (_swipeStartPosition == null) return;
    if (!_canSwipeSeek) {
      _cancelScrub();
      return;
    }
    final distance = details.globalPosition.dx - _swipeLastX;
    _swipeLastX = details.globalPosition.dx;
    _updateScrub(_scrub! + distance * _swipeSecondsPerPixel);
  }

  void _endSwipe(DragEndDetails details) {
    if (_swipeStartPosition == null) return;
    if (_canSwipeSeek) {
      unawaited(_commitScrub());
    } else {
      _cancelScrub();
    }
  }

  void _cancelSwipe() {
    if (_swipeStartPosition != null) _cancelScrub();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_holdingSpeed && _holdViewport != MediaQuery.sizeOf(context)) {
      _stopHoldSpeed();
    }
    if (_swipeStartPosition != null &&
        _swipeViewport != MediaQuery.sizeOf(context)) {
      _cancelScrub();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stopHoldSpeed();
    } else {
      unawaited(_restoreHoldSpeed());
    }
  }

  Future<void> _screenMode(bool expanded) async {
    await SystemChrome.setPreferredOrientations(
      expanded
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : DeviceOrientation.values,
    );
    await SystemChrome.setEnabledSystemUIMode(
      expanded ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_syncFullscreen);
    store.playback.removeListener(_playbackChanged);
    _stopHoldSpeed(rebuild: false);
    _hideTimer?.cancel();
    if (_fullscreen) unawaited(_screenMode(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, child) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: store.playerFullscreen ? _dismissOutsideVideo : null,
      child: _page(context),
    ),
  );

  Widget _page(BuildContext context) {
    if (store.playerFullscreen) return _cinema(context);
    final anime = store.playingAnime!;
    final detail = store.playerDetail;
    return GlassScaffold(
      key: const ValueKey('native-player-page'),
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: Text(
          store.t('nowPlaying'),
          style: const TextStyle(fontSize: 17),
        ),
        leading: GlassIconButton(
          semanticLabel: store.t('close'),
          icon: const Icon(CupertinoIcons.xmark),
          onPressed: store.closeBrowser,
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          MediaQuery.paddingOf(context).top + 60,
          20,
          40,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: AspectRatio(aspectRatio: 16 / 9, child: _surface()),
            ),
            ValueListenableBuilder(
              valueListenable: store.playback,
              builder: (context, state, child) => state.canOperate
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _controls(fullscreen: false),
                    )
                  : const SizedBox.shrink(),
            ),
            _status(),
            const SizedBox(height: 28),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    anime.title,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                GlassIconButton(
                  semanticLabel: store.t(
                    store.isFavorite(anime) ? 'unsave' : 'save',
                  ),
                  icon: Icon(
                    store.isFavorite(anime)
                        ? CupertinoIcons.bookmark_fill
                        : CupertinoIcons.bookmark,
                    color: brandBlue,
                  ),
                  onPressed: () => store.toggleFavorite(anime),
                ),
              ],
            ),
            if (store.playingEpisodeLabel.isNotEmpty || anime.year != null) ...[
              const SizedBox(height: 10),
              Text(
                [
                  anime.year,
                  _episodeLabel(store.playingEpisodeLabel),
                ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(color: secondary(context), fontSize: 13),
              ),
            ],
            const SizedBox(height: 28),
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
              LayoutBuilder(
                builder: (context, bounds) {
                  final count = (bounds.maxWidth / 62).floor().clamp(3, 8);
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final episode in detail.episodes)
                        SizedBox(
                          width: (bounds.maxWidth - (count - 1) * 10) / count,
                          child: CupertinoButton(
                            disabledColor: brandBlue,
                            padding: const EdgeInsets.symmetric(
                              vertical: 13,
                              horizontal: 3,
                            ),
                            color: episode.id == store.playingVideoId
                                ? brandBlue
                                : secondary(context).withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(15),
                            onPressed: episode.id == store.playingVideoId
                                ? null
                                : () => store.play(anime, episode: episode),
                            child: Text(
                              episode.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: episode.id == store.playingVideoId
                                    ? Colors.white
                                    : brandBlue,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            if (detail != null && detail.description.isNotEmpty) ...[
              const SizedBox(height: 30),
              SynopsisSection(
                store: store,
                title: anime.title,
                description: detail.description,
              ),
            ],
            if (store.playingVideoId != null) ...[
              const SizedBox(height: 28),
              CompactCommentsPreview(
                key: ValueKey('player-board-${store.playingVideoId}'),
                store: store,
                videoId: store.playingVideoId!,
                title: anime.title,
                rating: detail?.rating,
                episodes: detail?.episodes ?? const [],
                episodeLabel: store.playingEpisodeLabel,
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
                        width: 90,
                        child: Text(
                          item.label,
                          style: TextStyle(
                            color: secondary(context),
                            fontSize: 13,
                          ),
                        ),
                      ),
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
        ),
      ),
    );
  }

  String _episodeLabel(String value) =>
      RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value)
      ? store.t('episodeNumber').replaceAll('{n}', value)
      : value;

  Widget _gestureSurface() => Listener(
    // An accepted Flutter drag reports onEnd for PointerCancelEvent as well.
    // Cancel first so an interrupted touch cannot commit its preview target.
    onPointerCancel: (_) {
      _cancelSwipe();
      _stopHoldSpeed();
    },
    child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        if (_canSwipeSeek)
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(
                () => HorizontalDragGestureRecognizer(debugOwner: this),
                (instance) => instance
                  // A vertical movement can eliminate the tap recognizer,
                  // leaving a horizontal recognizer as the arena's default
                  // winner. It must still meet its own horizontal threshold.
                  ..onlyAcceptDragOnThreshold = true
                  ..dragStartBehavior = DragStartBehavior.down
                  ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                  ..onStart = _startSwipe
                  ..onUpdate = _updateSwipe
                  ..onEnd = _endSwipe
                  ..onCancel = _cancelSwipe,
              ),
      },
      child: GestureDetector(
        key: const ValueKey('player-controls-toggle'),
        behavior: HitTestBehavior.opaque,
        onTap: store.playerFullscreen ? _toggleControls : _revealControls,
        onDoubleTap: store.playerFullscreen
            ? () {
                final playback = store.playback.value;
                if (!store.playerLocked && playback.canControl) {
                  store.controlPlayer(playback.paused ? 'play' : 'pause');
                }
              }
            : null,
        onLongPressStart: _canHoldSpeed ? (_) => _startHoldSpeed() : null,
        onLongPressMoveUpdate: _canHoldSpeed
            ? (details) {
                final slop =
                    MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ??
                    kTouchSlop;
                if (details.offsetFromOrigin.distance > slop) _stopHoldSpeed();
              }
            : null,
        onLongPressEnd: _canHoldSpeed ? (_) => _stopHoldSpeed() : null,
        onLongPressCancel: _canHoldSpeed ? _stopHoldSpeed : null,
      ),
    ),
  );

  Widget _surface() => Stack(
    key: _videoSurfaceKey,
    fit: StackFit.expand,
    children: [
      widget.video,
      ValueListenableBuilder(
        valueListenable: store.playback,
        builder: (context, state, child) => Stack(
          fit: StackFit.expand,
          children: [
            if (!state.surfaceReady &&
                state.phase != PlaybackPhase.error &&
                !store.browserError)
              const ColoredBox(color: Colors.black),
            if (state.canControl) _gestureSurface(),
            if (_holdingSpeed)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 20,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Semantics(
                      liveRegion: true,
                      child: Container(
                        key: const ValueKey('player-hold-speed-indicator'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xbb101014),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              CupertinoIcons.forward_fill,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              store.t('holdSpeedActive'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_swipeStartPosition != null && _scrub != null)
              Center(
                child: IgnorePointer(
                  child: Semantics(
                    label: store.t('playbackProgress'),
                    child: Container(
                      key: const ValueKey('player-seek-preview'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xbb101014),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _scrub! >= _swipeStartPosition!
                                ? CupertinoIcons.forward_fill
                                : CupertinoIcons.backward_fill,
                            color: Colors.white,
                            size: 28,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${_time(_scrub!)} / ${_time(state.duration)}',
                            key: const ValueKey('player-seek-target'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_scrub! >= _swipeStartPosition! ? '+' : '−'}'
                            '${_time((_scrub! - _swipeStartPosition!).abs())}',
                            key: const ValueKey('player-seek-offset'),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (!store.browserError &&
                (state.phase == PlaybackPhase.loading ||
                    (state.phase == PlaybackPhase.content && state.buffering)))
              Center(
                child: IgnorePointer(
                  child: Semantics(
                    label: store.t('loading'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CupertinoActivityIndicator(
                          key: ValueKey('player-loading-indicator'),
                          color: Colors.white,
                          radius: 12,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _downloadSpeed(state.downloadBytesPerSecond),
                          key: const ValueKey('player-loading-speed'),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontFeatures: [FontFeature.tabularFigures()],
                            shadows: [
                              Shadow(color: Colors.black87, blurRadius: 4),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (!store.playerFullscreen)
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    if (!state.canOperate)
                      _videoAction(
                        CupertinoIcons.arrow_up_left_arrow_down_right,
                        'fullScreen',
                        () => store.setPlayerFullscreen(true),
                      ),
                    const SizedBox(width: 8),
                    ..._danmakuActions(),
                    const SizedBox(width: 8),
                    _videoAction(
                      CupertinoIcons.ellipsis,
                      'playbackSettings',
                      _settingsMenu,
                    ),
                  ],
                ),
              ),
            if (store.playerFullscreen &&
                state.canOperate &&
                !store.playerLocked)
              Positioned(
                left: 48,
                right: 48,
                bottom: MediaQuery.paddingOf(context).bottom + 18,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 100),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 620),
                        child: Listener(
                          onPointerDown: (_) => _revealControls(),
                          child: _controls(fullscreen: true),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  List<Widget> _danmakuActions() {
    final enabled = store.danmakuSettings.enabled;
    return [
      if (enabled) ...[
        GlassIconButton(
          key: const ValueKey('player-danmaku-send'),
          size: 36,
          iconSize: 19,
          useOwnLayer: true,
          platformViewBackdrop: true,
          settings: mediaGlass.copyWith(backerColor: const Color(0x66000000)),
          semanticLabel: store.t('sendDanmaku'),
          icon: const Icon(CupertinoIcons.paperplane, color: Colors.white),
          onPressed: () => showDanmakuComposer(context, store),
        ),
        const SizedBox(width: 8),
      ],
      GlassIconButton(
        key: const ValueKey('player-danmaku-button'),
        size: 36,
        iconSize: 19,
        useOwnLayer: true,
        platformViewBackdrop: true,
        settings: mediaGlass.copyWith(backerColor: const Color(0x66000000)),
        semanticLabel: store.t(enabled ? 'hideDanmaku' : 'showDanmaku'),
        icon: Icon(
          enabled
              ? CupertinoIcons.text_bubble_fill
              : CupertinoIcons.text_bubble,
          color: enabled ? Colors.white : Colors.white54,
        ),
        onPressed: () => store.setDanmakuSettings(
          store.danmakuSettings.copyWith(enabled: !enabled),
        ),
      ),
    ];
  }

  Widget _videoAction(IconData icon, String label, VoidCallback action) =>
      GlassIconButton(
        size: 32,
        iconSize: 18,
        useOwnLayer: true,
        platformViewBackdrop: true,
        settings: mediaGlass.copyWith(backerColor: const Color(0x66000000)),
        semanticLabel: store.t(label),
        icon: Icon(icon, color: Colors.white),
        onPressed: action,
      );

  Widget _status() => ValueListenableBuilder(
    valueListenable: store.playback,
    builder: (context, state, child) {
      final key = switch (state.phase) {
        PlaybackPhase.content => null,
        PlaybackPhase.age => 'playerAgeHint',
        PlaybackPhase.advertisement => null,
        PlaybackPhase.error => 'playerPlaybackError',
        PlaybackPhase.verification => 'officialVerificationHint',
        PlaybackPhase.official => 'playerConfirmHint',
        PlaybackPhase.loading => null,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (key != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                store.t(key),
                style: TextStyle(
                  color: secondary(context),
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
          if (store.verificationRequired)
            CupertinoButton(
              onPressed: store.openOfficial,
              child: Text(store.t('officialVerification')),
            ),
          if (state.phase == PlaybackPhase.error)
            CupertinoButton(
              onPressed: store.reloadBrowser,
              child: Text(store.t('retry')),
            ),
        ],
      );
    },
  );

  Widget _controls({required bool fullscreen}) => ValueListenableBuilder(
    valueListenable: store.playback,
    builder: (context, state, child) {
      final seekable = state.canControl && _swipeStartPosition == null;
      final duration = state.duration;
      final position = (_scrub ?? state.position).clamp(0.0, duration);
      final dark = Theme.of(context).brightness == Brightness.dark;
      final color = fullscreen || dark ? Colors.white : const Color(0xff1c1c1e);
      final compact = !fullscreen && MediaQuery.sizeOf(context).width < 350;
      final settings = fullscreen
          ? LiquidGlassSettings.ios27Dark.copyWith(
              backerColor: const Color(0x88101014),
            )
          : mediaGlass.copyWith(
              glassColor: dark
                  ? const Color(0x18ffffff)
                  : const Color(0x168e8e93),
              backerColor: dark ? const Color(0x301c1c1e) : Colors.transparent,
              thickness: 16,
              blur: 6,
              lightIntensity: dark ? .35 : .25,
              ambientStrength: .03,
              chromaticAberration: .02,
              shadow: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
                BoxShadow(
                  color: Color(0x06000000),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ],
            );
      return GlassContainer(
        key: const ValueKey('video-glass-controls'),
        useOwnLayer: true,
        platformViewBackdrop: fullscreen,
        quality: fullscreen ? null : GlassQuality.standard,
        shape: LiquidRoundedSuperellipse(borderRadius: fullscreen ? 28 : 22),
        settings: settings,
        padding: EdgeInsets.symmetric(
          horizontal: fullscreen ? 20 : 12,
          vertical: fullscreen ? 14 : 12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: fullscreen ? 32 : 30,
              child: Semantics(
                label: store.t('playbackProgress'),
                child: Listener(
                  onPointerCancel: (_) => _cancelScrub(),
                  child: BufferedPlaybackTrack(
                    key: const ValueKey('player-buffered-track'),
                    state: state,
                    color: color,
                    child: GlassSlider(
                      key: const ValueKey('player-progress-slider'),
                      value: position,
                      max: duration > 0 ? duration : 1,
                      thumbRadius: fullscreen ? 8 : 7,
                      trackHeight: 4,
                      activeColor: color,
                      inactiveColor: Colors.transparent,
                      onChangeStart: seekable ? _beginScrub : null,
                      onChanged: seekable ? _updateScrub : null,
                      onChangeEnd: seekable
                          ? (_) => unawaited(_commitScrub())
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                _control(
                  state.paused
                      ? CupertinoIcons.play_fill
                      : CupertinoIcons.pause_fill,
                  state.paused ? 'resumePlayback' : 'pausePlayback',
                  () => store.controlPlayer(state.paused ? 'play' : 'pause'),
                  color,
                  size: fullscreen ? 30 : 26,
                  minimumSize: fullscreen ? 52 : (compact ? 38 : 42),
                ),
                _control(
                  CupertinoIcons.gobackward_10,
                  'rewindTen',
                  seekable
                      ? () => store.controlPlayer(
                          'seek',
                          (state.position - 10).clamp(0, duration),
                        )
                      : null,
                  color,
                  size: fullscreen ? 27 : 24,
                  minimumSize: fullscreen ? 52 : (compact ? 38 : 42),
                ),
                _control(
                  CupertinoIcons.goforward_10,
                  'forwardTen',
                  seekable
                      ? () => store.controlPlayer(
                          'seek',
                          (state.position + 10).clamp(0, duration),
                        )
                      : null,
                  color,
                  size: fullscreen ? 27 : 24,
                  minimumSize: fullscreen ? 52 : (compact ? 38 : 42),
                ),
                Expanded(
                  child: Text(
                    '${_time(position)} / ${_time(duration)}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: TextStyle(
                      color: color,
                      fontSize: fullscreen ? 13 : (compact ? 10 : 11),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                _control(
                  state.muted
                      ? CupertinoIcons.speaker_slash_fill
                      : CupertinoIcons.speaker_2_fill,
                  state.muted ? 'unmutePlayback' : 'mutePlayback',
                  () => store.controlPlayer('mute'),
                  color,
                  size: fullscreen ? 26 : 23,
                  minimumSize: fullscreen ? 52 : (compact ? 38 : 42),
                ),
                _control(
                  store.playerFullscreen
                      ? CupertinoIcons.arrow_down_right_arrow_up_left
                      : CupertinoIcons.arrow_up_left_arrow_down_right,
                  store.playerFullscreen ? 'exitFullScreen' : 'fullScreen',
                  () => store.setPlayerFullscreen(!store.playerFullscreen),
                  color,
                  size: fullscreen ? 25 : 22,
                  minimumSize: fullscreen ? 52 : (compact ? 38 : 42),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  Widget _control(
    IconData icon,
    String label,
    VoidCallback? action,
    Color color, {
    double size = 25,
    double minimumSize = 36,
  }) => Semantics(
    label: store.t(label),
    button: true,
    child: CupertinoButton(
      minimumSize: Size(minimumSize, minimumSize),
      padding: EdgeInsets.zero,
      onPressed: action,
      child: Icon(
        icon,
        color: action == null ? color.withValues(alpha: .25) : color,
        size: size,
      ),
    ),
  );

  Future<T?> _showMenu<T>(WidgetBuilder builder) async {
    final route = _PlayerMenuRoute<T>(
      builder: builder,
      barrierLabel: CupertinoLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: CupertinoDynamicColor.resolve(
        kCupertinoModalBarrierColor,
        context,
      ),
    );
    final result = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<T>(route);
    // Finish removing the old sheet and its barrier before opening a submenu.
    await route.completed;
    return result;
  }

  void _speed(double current) => _showMenu<void>(
    (sheet) => CupertinoActionSheet(
      title: Text(store.t('playbackSpeed')),
      actions: [
        for (final rate in [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0])
          CupertinoActionSheetAction(
            isDefaultAction: rate == current,
            onPressed: () {
              Navigator.pop(sheet);
              store.controlPlayer('rate', rate);
            },
            child: Text('$rate×'.replaceAll('.0×', '×')),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(sheet),
        child: Text(store.t('close')),
      ),
    ),
  );

  Future<void> _settingsMenu() async {
    final state = store.playback.value;
    final action = await _showMenu<_PlayerMenuAction>(
      (sheet) => CupertinoActionSheet(
        title: Text(store.t('playbackSettings')),
        actions: [
          if (state.canControl && state.qualities.isNotEmpty)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheet, _PlayerMenuAction.quality),
              child: Text(
                '${store.t('videoQuality')} · ${state.quality == 0 ? store.t('automaticQuality') : '${state.quality}p'}',
              ),
            ),
          if (state.canControl)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheet, _PlayerMenuAction.speed),
              child: Text(store.t('playbackSpeed')),
            ),
          if (state.canControl && state.hasDanmaku)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheet, _PlayerMenuAction.danmaku),
              child: Text(store.t('danmakuSettings')),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheet, _PlayerMenuAction.refresh),
            child: Text(store.t('refresh')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: Text(store.t('close')),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _PlayerMenuAction.quality:
        _qualityMenu();
      case _PlayerMenuAction.speed:
        _speed(state.rate);
      case _PlayerMenuAction.danmaku:
        showDanmakuPanel(context, store);
      case _PlayerMenuAction.refresh:
        unawaited(store.reloadBrowser());
      case null:
        break;
    }
  }

  void _qualityMenu() {
    final state = store.playback.value;
    _showMenu<void>(
      (sheet) => CupertinoActionSheet(
        title: Text(store.t('videoQuality')),
        actions: [
          for (final height in [0, ...state.qualities])
            CupertinoActionSheetAction(
              isDefaultAction: state.quality == height,
              onPressed: () {
                Navigator.pop(sheet);
                store.controlPlayer('quality', height.toDouble());
              },
              child: Text(
                height == 0 ? store.t('automaticQuality') : '${height}p',
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: Text(store.t('close')),
        ),
      ),
    );
  }

  Widget _cinema(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(excluding: store.playerLocked, child: _surface()),
        if (!store.playerLocked)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 14,
            left: 20,
            right: 20,
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 100),
                child: Listener(
                  onPointerDown: (_) => _revealControls(),
                  child: Row(
                    children: [
                      GlassIconButton(
                        key: const ValueKey('player-fullscreen-close'),
                        useOwnLayer: true,
                        platformViewBackdrop: true,
                        settings: mediaGlass.copyWith(
                          backerColor: const Color(0x66000000),
                        ),
                        semanticLabel: store.t('exitFullScreen'),
                        onPressed: () => store.setPlayerFullscreen(false),
                        icon: const Icon(
                          CupertinoIcons.xmark,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          store.playingAnime!.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            shadows: [Shadow(blurRadius: 8)],
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      ..._danmakuActions(),
                      const SizedBox(width: 12),
                      GlassIconButton(
                        useOwnLayer: true,
                        platformViewBackdrop: true,
                        settings: mediaGlass.copyWith(
                          backerColor: const Color(0x66000000),
                        ),
                        semanticLabel: store.t('playbackSettings'),
                        onPressed: _settingsMenu,
                        icon: const Icon(
                          CupertinoIcons.ellipsis,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (store.playerLocked)
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('player-locked-surface'),
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
            ),
          ),
        Positioned(
          left: MediaQuery.paddingOf(context).left + 20,
          top: 0,
          bottom: 0,
          child: Center(
            child: ValueListenableBuilder(
              valueListenable: store.playback,
              builder: (context, state, child) {
                if (!store.playerLocked && !state.canControl) {
                  return const SizedBox.shrink();
                }
                return IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 100),
                    child: GlassIconButton(
                      key: ValueKey(
                        store.playerLocked ? 'player-unlock' : 'player-lock',
                      ),
                      useOwnLayer: true,
                      platformViewBackdrop: true,
                      settings: mediaGlass.copyWith(
                        backerColor: const Color(0x66000000),
                      ),
                      semanticLabel: store.t(
                        store.playerLocked ? 'unlockPlayer' : 'lockPlayer',
                      ),
                      onPressed: () => _setLocked(!store.playerLocked),
                      icon: Icon(
                        store.playerLocked
                            ? CupertinoIcons.lock_fill
                            : CupertinoIcons.lock_open,
                        color: Colors.white,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    ),
  );

  String _downloadSpeed(double bytesPerSecond) {
    if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return '0 B/s';
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${bytesPerSecond.round()} B/s';
  }

  String _time(double seconds) {
    final value = seconds.floor();
    final minutes = value ~/ 60;
    return '${minutes.toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
  }
}

enum _PlayerMenuAction { quality, speed, danmaku, refresh }

/// Keep the sheet and its barrier on one bounded animation. The default
/// Cupertino popup spring retains its barrier while the spring settles,
/// even after the sheet has already moved out of view.
class _PlayerMenuRoute<T> extends RawDialogRoute<T> {
  _PlayerMenuRoute({
    required WidgetBuilder builder,
    required super.barrierColor,
    required super.barrierLabel,
  }) : super(
         transitionDuration: const Duration(milliseconds: 160),
         pageBuilder: (context, animation, secondaryAnimation) =>
             CupertinoUserInterfaceLevel(
               data: CupertinoUserInterfaceLevelData.elevated,
               child: Builder(builder: builder),
             ),
         transitionBuilder: (context, animation, secondaryAnimation, child) =>
             Align(
               alignment: Alignment.bottomCenter,
               child: SlideTransition(
                 position: animation
                     .drive(CurveTween(curve: Curves.easeOutCubic))
                     .drive(
                       Tween<Offset>(
                         begin: const Offset(0, 1),
                         end: Offset.zero,
                       ),
                     ),
                 child: child,
               ),
             ),
       );

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 90);

  @override
  Curve get barrierCurve => Curves.linear;
}
