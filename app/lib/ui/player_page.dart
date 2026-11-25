import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
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
import 'glass_settings_menu.dart';
import 'layout.dart';
import 'synopsis_section.dart';

/// The complete app playback page. The session-owned video surface is passed
/// in so changing layouts never creates a second official player or session.
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    required this.store,
    required this.video,
    this.videoOnly = false,
    this.onEnterPictureInPicture,
    super.key,
  });
  final AppStore store;
  final Widget video;
  final bool videoOnly;
  final Future<bool> Function(Rect surface)? onEnterPictureInPicture;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  AppStore get store => widget.store;
  double? _scrub;
  String? _scrubDocument;
  int _scrubRevision = 0;
  String? _opSkipVideoId;
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
  bool _settingsMenuOpen = false;
  String _controlState = '';
  Timer? _hideTimer;
  final _settingsMenuController = GlassSettingsMenuController();
  final _inlinePlayerKey = GlobalKey(debugLabel: 'inline-player');
  final _videoSurfaceKey = GlobalKey(debugLabel: 'player-video-surface');
  late final ValueNotifier<_PlayerChromeState> _chromeState;
  // The top strip of the landscape surface never starts a seek. Pulling down
  // from the screen edge belongs to the system panel (status bar, notification
  // shade, Control Center), so a slightly slanted pull must not fast-forward.
  static const double _topSeekExemptHeight = 56;
  static final _overlayActionGlass = mediaGlass.copyWith(
    backerColor: const Color(0x66000000),
    saturation: 1.0,
  );
  static final _fullscreenControlGlass = LiquidGlassSettings.ios27Dark.copyWith(
    backerColor: const Color(0x88101014),
    saturation: 1.0,
  );
  static final _portraitControlGlassDark = mediaGlass.copyWith(
    glassColor: const Color(0x18ffffff),
    backerColor: const Color(0x301c1c1e),
    thickness: 16,
    blur: 6,
    lightIntensity: .35,
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
  static final _portraitControlGlassLight = mediaGlass.copyWith(
    glassColor: const Color(0x168e8e93),
    backerColor: Colors.transparent,
    thickness: 16,
    blur: 6,
    lightIntensity: .25,
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

  @override
  void initState() {
    super.initState();
    _chromeState = ValueNotifier(
      _PlayerChromeState.fromPlayback(
        store.playback.value,
        browserError: store.browserError,
      ),
    );
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_syncFullscreen);
    store.playback.addListener(_playbackChanged);
    _syncFullscreen();
    _playbackChanged();
  }

  void _playbackChanged() {
    final state = store.playback.value;
    _chromeState.value = _PlayerChromeState.fromPlayback(
      state,
      browserError: store.browserError,
    );
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
    if (!_settingsMenuOpen &&
        _scrub == null &&
        store.playerFullscreen &&
        (store.playerLocked ||
            (state.phase == PlaybackPhase.content && !state.paused))) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _controlsVisible = false);
      });
    }
  }

  void _hideControls() {
    if (_settingsMenuOpen) return;
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
    if (locked) _settingsMenuController.close();
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
    _chromeState.value = _PlayerChromeState.fromPlayback(
      store.playback.value,
      browserError: store.browserError,
    );
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
    _settingsMenuController.close();
    _fullscreen = store.playerFullscreen;
    _revealControls();
    unawaited(_screenMode(_fullscreen));
  }

  bool get _canSwipeSeek =>
      (MediaQuery.orientationOf(context) == Orientation.landscape ||
          (store.playerFullscreen && AppLayout.of(context).isTablet)) &&
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

  bool get _canSkipOp {
    final state = store.playback.value;
    return store.skipOpLongPress &&
        store.applicationActive &&
        !store.playerLocked &&
        state.canControl &&
        state.duration >= 300 &&
        state.position < 240 &&
        _opSkipVideoId != store.playingVideoId;
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
    try {
      await store.controlPlayer('seek', target);
    } catch (_) {
      // A failed seek keeps the decoder's actual position.
    } finally {
      if (mounted && revision == _scrubRevision) _cancelScrub();
    }
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
    // DragStartBehavior.down reports where the finger landed. Ignore the top
    // strip so a pull-down for the system panel is never read as a seek.
    if (surface.globalToLocal(details.globalPosition).dy <
        MediaQuery.paddingOf(context).top + _topSeekExemptHeight) {
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
    final tablet = mounted && AppLayout.of(context).isTablet;
    await SystemChrome.setPreferredOrientations(
      expanded && !tablet
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
    _chromeState.dispose();
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
    if (widget.videoOnly) return SizedBox.expand(child: _video());
    if (store.playerFullscreen) return _cinema(context);
    final layout = AppLayout.of(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 820);
    final safe = MediaQuery.paddingOf(context);
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
      body: layout.useSplitPlayer
          ? _splitTheaterBody(context, layout)
          : CustomScrollView(
              slivers: [
                _inlinePlayer(context, hPad),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    hPad.left,
                    0,
                    hPad.right,
                    safe.bottom + 40,
                  ),
                  sliver: SliverToBoxAdapter(child: _playbackDetails(context)),
                ),
              ],
            ),
    );
  }

  Widget _splitTheaterBody(BuildContext context, AppLayout layout) {
    final safe = MediaQuery.paddingOf(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 1380);
    final bottomPad = safe.bottom + 24;
    return Padding(
      key: const ValueKey('player-split-layout'),
      padding: EdgeInsets.fromLTRB(hPad.left, safe.top + 56, hPad.right, 0),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final gap = layout.width >= 1120 ? 28.0 : 22.0;
          final sideWidth = (bounds.maxWidth * .35).clamp(320.0, 420.0);
          final leftWidth = math.max(320.0, bounds.maxWidth - sideWidth - gap);
          final maxVideoHeight = math.max(200.0, bounds.maxHeight - 170.0);
          final videoWidth = math.min(leftWidth, maxVideoHeight * (16 / 9));
          final halfGap = (gap - 0.5) / 2;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: leftWidth,
                child: SingleChildScrollView(
                  key: const PageStorageKey('player-theater-left'),
                  padding: EdgeInsets.only(bottom: bottomPad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: SizedBox(
                          key: _inlinePlayerKey,
                          width: videoWidth,
                          child: Column(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: _surface(),
                                ),
                              ),
                              ValueListenableBuilder(
                                valueListenable: _chromeState,
                                builder: (context, chrome, child) =>
                                    chrome.canOperate
                                    ? Padding(
                                        padding: const EdgeInsets.only(top: 12),
                                        child: _controls(
                                          chrome: chrome,
                                          fullscreen: false,
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      _status(),
                      const SizedBox(height: 20),
                      _titleHeader(context),
                    ],
                  ),
                ),
              ),
              SizedBox(width: halfGap),
              Container(
                width: 0.5,
                margin: EdgeInsets.only(bottom: bottomPad),
                color: secondary(context).withValues(alpha: .14),
              ),
              SizedBox(width: halfGap),
              SizedBox(
                width: sideWidth,
                child: SingleChildScrollView(
                  key: const PageStorageKey('player-theater-sidebar'),
                  padding: EdgeInsets.only(bottom: bottomPad),
                  child: _companionDetails(context, maxEpisodeColumns: 6),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _inlinePlayer(BuildContext context, EdgeInsets hPad) {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final media = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final contentWidth = math.max(0.0, media.width - hPad.left - hPad.right);
    final estimatedHeaderHeight = safe.top + 60 + contentWidth / (16 / 9);
    final canPin = portrait && media.height - estimatedHeaderHeight >= 220;
    return ValueListenableBuilder(
      valueListenable: _chromeState,
      builder: (context, chrome, child) {
        final pinned =
            canPin &&
            chrome.phase == PlaybackPhase.content &&
            chrome.surfaceReady &&
            !chrome.paused &&
            !chrome.ended;
        return pinned
            ? PinnedHeaderSliver(child: child)
            : SliverToBoxAdapter(child: child);
      },
      child: ColoredBox(
        key: _inlinePlayerKey,
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Padding(
          padding: EdgeInsets.fromLTRB(hPad.left, safe.top + 60, hPad.right, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: AspectRatio(aspectRatio: 16 / 9, child: _surface()),
          ),
        ),
      ),
    );
  }

  Widget _titleHeader(BuildContext context) {
    final anime = store.playingAnime!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
      ],
    );
  }

  Widget _companionDetails(
    BuildContext context, {
    int maxEpisodeColumns = 10,
  }) {
    final anime = store.playingAnime!;
    final detail = store.playerDetail;
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
          LayoutBuilder(
            builder: (context, bounds) {
              final count = (bounds.maxWidth / 62)
                  .floor()
                  .clamp(3, maxEpisodeColumns);
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
                      style: TextStyle(color: secondary(context), fontSize: 13),
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
    );
  }

  Widget _playbackDetails(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ValueListenableBuilder(
        valueListenable: _chromeState,
        builder: (context, chrome, child) => chrome.canOperate
            ? Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _controls(chrome: chrome, fullscreen: false),
              )
            : const SizedBox.shrink(),
      ),
      _status(),
      const SizedBox(height: 28),
      _titleHeader(context),
      const SizedBox(height: 28),
      _companionDetails(context),
    ],
  );

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
        onDoubleTap:
            store.playerFullscreen ||
                MediaQuery.orientationOf(context) == Orientation.portrait
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

  Widget _video() => KeyedSubtree(key: _videoSurfaceKey, child: widget.video);

  Widget _surface() => Stack(
    fit: StackFit.expand,
    children: [
      _video(),
      ValueListenableBuilder(
        valueListenable: _chromeState,
        builder: (context, chrome, child) => Stack(
          fit: StackFit.expand,
          children: [
            if (!chrome.surfaceReady &&
                !store.usesNativeHttpPlayback &&
                chrome.phase != PlaybackPhase.error &&
                !store.browserError)
              const ColoredBox(color: Colors.black),
            if (chrome.canControl) _gestureSurface(),
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
                            '${_formatPlaybackTime(_scrub!)} / ${_formatPlaybackTime(chrome.duration)}',
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
                            '${_formatPlaybackTime((_scrub! - _swipeStartPosition!).abs())}',
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
                (chrome.phase == PlaybackPhase.loading ||
                    (chrome.phase == PlaybackPhase.content &&
                        chrome.buffering)))
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
                        ValueListenableBuilder(
                          valueListenable: store.playback,
                          builder: (context, state, _) => Text(
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
                    if (!chrome.canOperate)
                      _videoAction(
                        CupertinoIcons.arrow_up_left_arrow_down_right,
                        'fullScreen',
                        () => store.setPlayerFullscreen(true),
                      ),
                    const SizedBox(width: 8),
                    _pictureInPictureButton(chrome),
                    ..._danmakuActions(),
                    const SizedBox(width: 8),
                    _settingsButton(fullscreen: false),
                  ],
                ),
              ),
            if (store.playerFullscreen &&
                chrome.canOperate &&
                !store.playerLocked)
              Positioned(
                left: math.max(48.0, MediaQuery.paddingOf(context).left + 24),
                right: math.max(48.0, MediaQuery.paddingOf(context).right + 24),
                bottom: MediaQuery.paddingOf(context).bottom + 18,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 100),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: AppLayout.of(context).isWide ? 720 : 620,
                        ),
                        child: Listener(
                          onPointerDown: (_) => _revealControls(),
                          child: _controls(chrome: chrome, fullscreen: true),
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
          settings: _overlayActionGlass,
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
        settings: _overlayActionGlass,
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

  Widget _pictureInPictureButton(_PlayerChromeState chrome) {
    if (widget.onEnterPictureInPicture == null ||
        !chrome.canControl ||
        chrome.ended) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: _videoAction(
        Icons.picture_in_picture_alt_outlined,
        'pictureInPicture',
        () => unawaited(_enterPictureInPicture()),
        key: const ValueKey('player-picture-in-picture'),
      ),
    );
  }

  Future<void> _enterPictureInPicture() async {
    final enter = widget.onEnterPictureInPicture;
    final surface = _videoSurfaceKey.currentContext?.findRenderObject();
    if (enter == null || surface is! RenderBox || !surface.hasSize) return;
    final document = store.operation.id;
    final started = await enter(
      surface.localToGlobal(Offset.zero) & surface.size,
    );
    if (started ||
        !mounted ||
        !store.applicationActive ||
        document != store.operation.id) {
      return;
    }
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(store.t('pictureInPicture')),
        content: Text(store.t('pictureInPictureUnavailable')),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog),
            child: Text(store.t('close')),
          ),
        ],
      ),
    );
  }

  Widget _videoAction(
    IconData icon,
    String label,
    VoidCallback action, {
    Key? key,
  }) => GlassIconButton(
    key: key,
    size: 32,
    iconSize: 18,
    useOwnLayer: true,
    platformViewBackdrop: true,
    settings: _overlayActionGlass,
    semanticLabel: store.t(label),
    icon: Icon(icon, color: Colors.white),
    onPressed: action,
  );

  Widget _status() => ValueListenableBuilder(
    valueListenable: _chromeState,
    builder: (context, chrome, child) {
      final key = switch (chrome.phase) {
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
          if (chrome.phase == PlaybackPhase.error)
            CupertinoButton(
              onPressed: store.retryPlayback,
              child: Text(store.t('retry')),
            ),
        ],
      );
    },
  );

  Widget _controls({
    required _PlayerChromeState chrome,
    required bool fullscreen,
  }) {
    final seekable = chrome.canControl && _swipeStartPosition == null;
    final active = !fullscreen || _controlsVisible || _scrub != null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = fullscreen || dark ? Colors.white : const Color(0xff1c1c1e);
    final compact = !fullscreen && MediaQuery.sizeOf(context).width < 350;
    final settings = fullscreen
        ? _fullscreenControlGlass
        : dark
        ? _portraitControlGlassDark
        : _portraitControlGlassLight;
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
          _PlaybackProgressBar(
            playback: store.playback,
            active: active,
            seekable: seekable,
            fullscreen: fullscreen,
            color: color,
            label: store.t('playbackProgress'),
            scrub: _scrub,
            onBeginScrub: _beginScrub,
            onUpdateScrub: _updateScrub,
            onCommitScrub: () => unawaited(_commitScrub()),
            onCancelScrub: _cancelScrub,
          ),
          Row(
            children: [
              _control(
                chrome.paused
                    ? CupertinoIcons.play_fill
                    : CupertinoIcons.pause_fill,
                chrome.paused ? 'resumePlayback' : 'pausePlayback',
                () => store.controlPlayer(chrome.paused ? 'play' : 'pause'),
                color,
                size: fullscreen ? 30 : 26,
                minimumSize: fullscreen ? 52 : (compact ? 38 : 42),
              ),
              _control(
                CupertinoIcons.gobackward_10,
                'rewindTen',
                seekable
                    ? () {
                        final playback = store.playback.value;
                        store.controlPlayer(
                          'seek',
                          (playback.position - 10).clamp(0, playback.duration),
                        );
                      }
                    : null,
                color,
                size: fullscreen ? 27 : 24,
                minimumSize: fullscreen ? 52 : (compact ? 38 : 42),
              ),
              _control(
                CupertinoIcons.goforward_10,
                'forwardTen',
                seekable
                    ? () {
                        final playback = store.playback.value;
                        store.controlPlayer(
                          'seek',
                          (playback.position + 10).clamp(0, playback.duration),
                        );
                      }
                    : null,
                color,
                size: fullscreen ? 27 : 24,
                minimumSize: fullscreen ? 52 : (compact ? 38 : 42),
                onLongPress: seekable && _canSkipOp
                    ? () {
                        if (!mounted || !_canSkipOp) return;
                        HapticFeedback.mediumImpact();
                        final playback = store.playback.value;
                        setState(() => _opSkipVideoId = store.playingVideoId);
                        store.controlPlayer(
                          'seek',
                          (playback.position + 85).clamp(0, playback.duration),
                        );
                      }
                    : null,
              ),
              Expanded(
                child: _PlaybackTimeText(
                  playback: store.playback,
                  active: active,
                  scrub: _scrub,
                  style: TextStyle(
                    color: color,
                    fontSize: fullscreen ? 13 : (compact ? 10 : 11),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              _control(
                chrome.muted
                    ? CupertinoIcons.speaker_slash_fill
                    : CupertinoIcons.speaker_2_fill,
                chrome.muted ? 'unmutePlayback' : 'mutePlayback',
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
  }

  Widget _control(
    IconData icon,
    String label,
    VoidCallback? action,
    Color color, {
    double size = 25,
    double minimumSize = 36,
    VoidCallback? onLongPress,
  }) => Semantics(
    label: store.t(label),
    button: true,
    child: CupertinoButton(
      minimumSize: Size(minimumSize, minimumSize),
      padding: EdgeInsets.zero,
      onPressed: action,
      onLongPress: onLongPress,
      child: Icon(
        icon,
        color: action == null ? color.withValues(alpha: .25) : color,
        size: size,
      ),
    ),
  );

  String _rateLabel(double rate) => '$rate×'.replaceAll('.0×', '×');

  String _qualityLabel(int height) =>
      height == 0 ? store.t('automaticQuality') : '${height}p';

  Widget _settingsButton({required bool fullscreen}) => ValueListenableBuilder(
    valueListenable: _chromeState,
    builder: (context, chrome, child) {
      final forceDark = fullscreen;
      final items = <Widget>[
        if (chrome.canControl && chrome.qualities.isNotEmpty)
          glassSettingsSubmenuItem(
            context,
            key: const ValueKey('player-menu-quality'),
            icon: CupertinoIcons.slider_horizontal_3,
            title: store.t('videoQuality'),
            value: _qualityLabel(chrome.quality),
            forceDark: forceDark,
            submenu: [
              for (final height in [0, ...chrome.qualities])
                glassSettingsOptionItem(
                  context,
                  key: ValueKey('player-quality-$height'),
                  title: _qualityLabel(height),
                  selected: chrome.quality == height,
                  forceDark: forceDark,
                  onTap: () => store.controlPlayer('quality', height.toDouble()),
                ),
            ],
          ),
        if (chrome.canControl)
          glassSettingsSubmenuItem(
            context,
            key: const ValueKey('player-menu-speed'),
            icon: CupertinoIcons.gauge,
            title: store.t('playbackSpeed'),
            value: _rateLabel(chrome.rate),
            forceDark: forceDark,
            submenu: [
              for (final rate in [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0])
                glassSettingsOptionItem(
                  context,
                  key: ValueKey('player-speed-$rate'),
                  title: _rateLabel(rate),
                  selected: rate == chrome.rate,
                  forceDark: forceDark,
                  onTap: () => store.controlPlayer('rate', rate),
                ),
            ],
          ),
        if (chrome.canControl && chrome.hasDanmaku)
          glassSettingsActionItem(
            context,
            key: const ValueKey('player-menu-danmaku'),
            icon: CupertinoIcons.text_bubble,
            title: store.t('danmakuSettings'),
            forceDark: forceDark,
            onTap: () => showDanmakuPanel(context, store),
          ),
        glassSettingsActionItem(
          context,
          key: const ValueKey('player-menu-refresh'),
          icon: CupertinoIcons.arrow_clockwise,
          title: store.t('refresh'),
          forceDark: forceDark,
          onTap: () => unawaited(store.reloadBrowser()),
        ),
      ];
      return GlassSettingsMenu(
        controller: _settingsMenuController,
        menuAlignment: GlassMenuAlignment.topRight,
        platformViewBackdrop: true,
        forceDark: forceDark,
        onOpen: () {
          _settingsMenuOpen = true;
          _hideTimer?.cancel();
        },
        onClose: () {
          _settingsMenuOpen = false;
          _revealControls();
        },
        items: items,
        triggerBuilder: (context, toggleMenu) => fullscreen
            ? GlassIconButton(
                useOwnLayer: true,
                platformViewBackdrop: true,
                settings: _overlayActionGlass,
                semanticLabel: store.t('playbackSettings'),
                onPressed: toggleMenu,
                icon: const Icon(CupertinoIcons.ellipsis, color: Colors.white),
              )
            : _videoAction(
                CupertinoIcons.ellipsis,
                'playbackSettings',
                toggleMenu,
              ),
      );
    },
  );

  Widget _cinema(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(excluding: store.playerLocked, child: _surface()),
        if (!store.playerLocked)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 14,
            left: math.max(20.0, MediaQuery.paddingOf(context).left + 12),
            right: math.max(20.0, MediaQuery.paddingOf(context).right + 12),
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
                        settings: _overlayActionGlass,
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
                      ValueListenableBuilder(
                        valueListenable: _chromeState,
                        builder: (context, chrome, child) =>
                            _pictureInPictureButton(chrome),
                      ),
                      ..._danmakuActions(),
                      const SizedBox(width: 12),
                      _settingsButton(fullscreen: true),
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
              valueListenable: _chromeState,
              builder: (context, chrome, child) {
                if (!store.playerLocked && !chrome.canControl) {
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
                      settings: _overlayActionGlass,
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
}

String _formatPlaybackTime(double seconds) {
  final value = seconds.floor();
  final minutes = value ~/ 60;
  return '${minutes.toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
}

@immutable
class _PlayerChromeState {
  const _PlayerChromeState({
    required this.phase,
    required this.surfaceReady,
    required this.canOperate,
    required this.canControl,
    required this.paused,
    required this.muted,
    required this.buffering,
    required this.ended,
    required this.hasDanmaku,
    required this.browserError,
    required this.quality,
    required this.qualities,
    required this.duration,
    required this.rate,
  });

  factory _PlayerChromeState.fromPlayback(
    PlaybackState state, {
    required bool browserError,
  }) => _PlayerChromeState(
    phase: state.phase,
    surfaceReady: state.surfaceReady,
    canOperate: state.canOperate,
    canControl: state.canControl,
    paused: state.paused,
    muted: state.muted,
    buffering: state.buffering,
    ended: state.ended,
    hasDanmaku: state.hasDanmaku,
    browserError: browserError,
    quality: state.quality,
    qualities: state.qualities,
    duration: state.duration,
    rate: state.rate,
  );

  final PlaybackPhase phase;
  final bool surfaceReady, canOperate, canControl, paused, muted, buffering;
  final bool ended, hasDanmaku, browserError;
  final int quality;
  final List<int> qualities;
  final double duration, rate;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _PlayerChromeState &&
          phase == other.phase &&
          surfaceReady == other.surfaceReady &&
          canOperate == other.canOperate &&
          canControl == other.canControl &&
          paused == other.paused &&
          muted == other.muted &&
          buffering == other.buffering &&
          ended == other.ended &&
          hasDanmaku == other.hasDanmaku &&
          browserError == other.browserError &&
          quality == other.quality &&
          listEquals(qualities, other.qualities) &&
          duration == other.duration &&
          rate == other.rate;

  @override
  int get hashCode => Object.hash(
    phase,
    surfaceReady,
    canOperate,
    canControl,
    paused,
    muted,
    buffering,
    ended,
    hasDanmaku,
    browserError,
    quality,
    Object.hashAll(qualities),
    duration,
    rate,
  );
}

class _PlaybackProgressBar extends StatefulWidget {
  const _PlaybackProgressBar({
    required this.playback,
    required this.active,
    required this.seekable,
    required this.fullscreen,
    required this.color,
    required this.label,
    required this.scrub,
    required this.onBeginScrub,
    required this.onUpdateScrub,
    required this.onCommitScrub,
    required this.onCancelScrub,
  });

  final ValueListenable<PlaybackState> playback;
  final bool active, seekable, fullscreen;
  final Color color;
  final String label;
  final double? scrub;
  final ValueChanged<double> onBeginScrub;
  final ValueChanged<double> onUpdateScrub;
  final VoidCallback onCommitScrub;
  final VoidCallback onCancelScrub;

  @override
  State<_PlaybackProgressBar> createState() => _PlaybackProgressBarState();
}

class _PlaybackProgressBarState extends State<_PlaybackProgressBar> {
  late PlaybackState _state;

  @override
  void initState() {
    super.initState();
    _state = widget.playback.value;
    if (widget.active) widget.playback.addListener(_onPlayback);
  }

  @override
  void didUpdateWidget(covariant _PlaybackProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      if (oldWidget.active) oldWidget.playback.removeListener(_onPlayback);
      _state = widget.playback.value;
      if (widget.active) widget.playback.addListener(_onPlayback);
    } else if (oldWidget.active != widget.active) {
      if (widget.active) {
        _state = widget.playback.value;
        widget.playback.addListener(_onPlayback);
      } else {
        widget.playback.removeListener(_onPlayback);
      }
    }
  }

  void _onPlayback() {
    if (!mounted || !widget.active) return;
    setState(() => _state = widget.playback.value);
  }

  @override
  void dispose() {
    if (widget.active) widget.playback.removeListener(_onPlayback);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = _state.duration;
    final position = (widget.scrub ?? _state.position).clamp(0.0, duration);
    return SizedBox(
      height: widget.fullscreen ? 32 : 30,
      child: Semantics(
        label: widget.label,
        child: Listener(
          onPointerCancel: (_) => widget.onCancelScrub(),
          child: BufferedPlaybackTrack(
            key: const ValueKey('player-buffered-track'),
            state: _state,
            color: widget.color,
            child: GlassSlider(
              key: const ValueKey('player-progress-slider'),
              value: position,
              max: duration > 0 ? duration : 1,
              thumbRadius: widget.fullscreen ? 8 : 7,
              trackHeight: 4,
              activeColor: widget.color,
              inactiveColor: Colors.transparent,
              onChangeStart: widget.seekable ? widget.onBeginScrub : null,
              onChanged: widget.seekable ? widget.onUpdateScrub : null,
              onChangeEnd: widget.seekable
                  ? (_) => widget.onCommitScrub()
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaybackTimeText extends StatefulWidget {
  const _PlaybackTimeText({
    required this.playback,
    required this.active,
    required this.scrub,
    required this.style,
  });

  final ValueListenable<PlaybackState> playback;
  final bool active;
  final double? scrub;
  final TextStyle style;

  @override
  State<_PlaybackTimeText> createState() => _PlaybackTimeTextState();
}

class _PlaybackTimeTextState extends State<_PlaybackTimeText> {
  late int _positionSeconds;
  late int _durationSeconds;

  void _capture() {
    final state = widget.playback.value;
    final duration = state.duration;
    final position = (widget.scrub ?? state.position).clamp(0.0, duration);
    _positionSeconds = position.floor();
    _durationSeconds = duration.floor();
  }

  @override
  void initState() {
    super.initState();
    _capture();
    if (widget.active) widget.playback.addListener(_onPlayback);
  }

  @override
  void didUpdateWidget(covariant _PlaybackTimeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      if (oldWidget.active) oldWidget.playback.removeListener(_onPlayback);
      _capture();
      if (widget.active) widget.playback.addListener(_onPlayback);
    } else {
      if (oldWidget.active != widget.active) {
        if (widget.active) {
          _capture();
          widget.playback.addListener(_onPlayback);
        } else {
          widget.playback.removeListener(_onPlayback);
        }
      } else if (oldWidget.scrub != widget.scrub) {
        _capture();
      }
    }
  }

  void _onPlayback() {
    if (!mounted || !widget.active) return;
    final state = widget.playback.value;
    final duration = state.duration;
    final position = (widget.scrub ?? state.position).clamp(0.0, duration);
    final posSec = position.floor();
    final durSec = duration.floor();
    if (posSec == _positionSeconds && durSec == _durationSeconds) return;
    setState(() {
      _positionSeconds = posSec;
      _durationSeconds = durSec;
    });
  }

  @override
  void dispose() {
    if (widget.active) widget.playback.removeListener(_onPlayback);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String fmt(int value) {
      final minutes = value ~/ 60;
      return '${minutes.toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
    }

    return Text(
      '${fmt(_positionSeconds)} / ${fmt(_durationSeconds)}',
      textAlign: TextAlign.center,
      maxLines: 1,
      style: widget.style,
    );
  }
}
