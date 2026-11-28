import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart'
    show DragStartBehavior, HorizontalDragGestureRecognizer, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../core/playback_state.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'community_widgets.dart' show formatEpisodeNumberLabel;
import 'danmaku_panel.dart';
import 'glass_alert.dart';
import 'glass_settings_menu.dart';
import 'layout.dart';
import 'player_companion_section.dart';
import 'player_controls.dart';
import 'player_episodes_dialog.dart';

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
  final _scrubPosition = ValueNotifier<double?>(null);
  final _controlsVisible = ValueNotifier<bool>(true);
  final _holdingSpeed = ValueNotifier<bool>(false);
  final _swipeStart = ValueNotifier<double?>(null);
  final _toggleFlashIcon = ValueNotifier<IconData?>(null);
  final _opSkipVideoId = ValueNotifier<String?>(null);
  final _hudListenable = <Listenable>[];
  late final Listenable _surfaceHudListenable;
  String? _scrubDocument;
  int _scrubRevision = 0;
  bool _activelyScrubbing = false;
  bool _isHoldingSpeed = false;
  double _swipeLastX = 0;
  double _swipeSecondsPerPixel = 0;
  Size? _swipeViewport;
  double? _holdOriginalRate;
  String? _holdDocument;
  Size? _holdViewport;
  Future<void>? _holdStart;
  bool _restoringHoldSpeed = false;
  bool _fullscreen = false;
  bool _isTablet = false;
  bool _settingsMenuOpen = false;
  bool _apronScrubbing = false;
  bool? _silentPauseToggleTarget;
  PlaybackPhase? _controlPhase;
  bool? _controlPaused;
  Timer? _hideTimer;
  Timer? _toggleFlashTimer;
  double? _pendingRelativeTarget;
  int _relativeSeekToken = 0;
  Object? _companionCacheKey;
  Widget? _companionCacheWidget;
  final _settingsMenuController = GlassSettingsMenuController();
  final _inlinePlayerKey = GlobalKey(debugLabel: 'inline-player');
  final _videoSurfaceKey = GlobalKey(debugLabel: 'player-video-surface');
  final _fullscreenSliderKey = GlobalKey(debugLabel: 'fullscreen-slider');
  late final ValueNotifier<PlayerChromeState> _chromeState;
  // The top strip of the landscape surface never starts a seek. Pulling down
  // from the screen edge belongs to the system panel (status bar, notification
  // shade, Control Center), so a slightly slanted pull must not fast-forward.
  static const double _topSeekExemptHeight = 56;
  static final _overlayActionGlass = mediaGlass.copyWith(
    backerColor: const Color(0x58000000),
    saturation: 1.0,
  );
  static final _fullscreenControlGlass = LiquidGlassSettings.ios27Dark.copyWith(
    backerColor: const Color(0x72101014),
    saturation: 1.0,
  );
  static final _fullscreenWingGlass = LiquidGlassSettings.ios27Dark.copyWith(
    backerColor: const Color(0x5A101014),
    saturation: 1.0,
  );
  static final _fullscreenScrubberGlass = LiquidGlassSettings.ios27Dark
      .copyWith(backerColor: const Color(0x42101014), saturation: 1.0);
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
      PlayerChromeState.fromPlayback(
        store.playback.value,
        browserError: store.browserError,
      ),
    );
    _hudListenable.addAll([_chromeState, _swipeStart, _opSkipVideoId]);
    _surfaceHudListenable = Listenable.merge(_hudListenable);
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_syncFullscreen);
    store.playback.addListener(_playbackChanged);
    _playbackChanged();
  }

  void _playbackChanged() {
    final state = store.playback.value;
    if (_opSkipVideoId.value != null &&
        _opSkipVideoId.value == store.playingVideoId &&
        state.position < 30) {
      _opSkipVideoId.value = null;
    }
    _chromeState.value = PlayerChromeState.fromPlayback(
      state,
      browserError: store.browserError,
    );
    if (_isHoldingSpeed && !_canHoldSpeed) _stopHoldSpeed();
    if (!_isHoldingSpeed &&
        _holdOriginalRate != null &&
        !_restoringHoldSpeed) {
      unawaited(_restoreHoldSpeed());
    }
    if (_scrubPosition.value != null &&
        (!state.canControl || _scrubDocument != store.operation.id)) {
      _cancelScrub();
    }
    if (store.playerLocked &&
        state.phase != PlaybackPhase.content &&
        state.phase != PlaybackPhase.loading) {
      store.setPlayerLocked(false);
    }
    if (state.phase == _controlPhase && state.paused == _controlPaused) return;
    final phaseChanged = state.phase != _controlPhase;
    _controlPhase = state.phase;
    _controlPaused = state.paused;
    if (!phaseChanged &&
        store.playerFullscreen &&
        !_controlsVisible.value &&
        state.phase == PlaybackPhase.content &&
        _silentPauseToggleTarget == state.paused) {
      _silentPauseToggleTarget = null;
      return;
    }
    _silentPauseToggleTarget = null;
    _revealControls();
  }

  void _revealControls() {
    _silentPauseToggleTarget = null;
    _hideTimer?.cancel();
    if (!_controlsVisible.value && mounted) _controlsVisible.value = true;
    final state = store.playback.value;
    if (!_settingsMenuOpen &&
        _scrubPosition.value == null &&
        store.playerFullscreen &&
        (store.playerLocked ||
            (state.phase == PlaybackPhase.content && !state.paused))) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) _controlsVisible.value = false;
      });
    }
  }

  void _hideControls() {
    if (_settingsMenuOpen) return;
    _hideTimer?.cancel();
    if (_controlsVisible.value && mounted) _controlsVisible.value = false;
  }

  void _toggleControls() {
    if (_controlsVisible.value) {
      _hideControls();
    } else {
      _revealControls();
    }
  }

  void _flashToggleIcon(IconData icon) {
    _toggleFlashTimer?.cancel();
    _toggleFlashIcon.value = icon;
    _toggleFlashTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _toggleFlashIcon.value = null;
    });
  }

  Future<void> _withMenuHold(Future<void> Function() action) async {
    _settingsMenuOpen = true;
    _hideTimer?.cancel();
    try {
      await action();
    } finally {
      _settingsMenuOpen = false;
      if (mounted) _revealControls();
    }
  }

  void _setLocked(bool locked) {
    _silentPauseToggleTarget = null;
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
    _chromeState.value = PlayerChromeState.fromPlayback(
      store.playback.value,
      browserError: store.browserError,
    );
    if (_isHoldingSpeed &&
        (store.playerLocked ||
            _holdDocument != store.operation.id ||
            _fullscreen != store.playerFullscreen)) {
      _stopHoldSpeed();
    }
    if (!_isHoldingSpeed &&
        _holdOriginalRate != null &&
        !_restoringHoldSpeed) {
      unawaited(_restoreHoldSpeed());
    }
    if (_scrubPosition.value != null &&
        (store.playerLocked ||
            _scrubDocument != store.operation.id ||
            _fullscreen != store.playerFullscreen)) {
      _cancelScrub();
    }
    if (_fullscreen == store.playerFullscreen) return;
    _silentPauseToggleTarget = null;
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
        _scrubPosition.value == null;
  }

  bool get _canSkipOp {
    final state = store.playback.value;
    return store.skipOpLongPress &&
        store.applicationActive &&
        !store.playerLocked &&
        state.canControl &&
        state.duration >= 300 &&
        state.position < 240 &&
        _opSkipVideoId.value != store.playingVideoId;
  }

  void _startHoldSpeed() {
    if (!_canHoldSpeed || _holdOriginalRate != null) return;
    _isHoldingSpeed = true;
    _holdOriginalRate = store.playback.value.rate;
    _holdDocument = store.operation.id;
    _holdViewport = MediaQuery.sizeOf(context);
    _holdingSpeed.value = true;
    _holdStart = store.controlPlayer('rate', 2);
  }

  void _stopHoldSpeed({bool rebuild = true}) {
    if (_isHoldingSpeed) {
      _isHoldingSpeed = false;
      _holdViewport = null;
      if (rebuild && mounted) {
        _holdingSpeed.value = false;
      }
    }
    if (_holdOriginalRate != null && !_restoringHoldSpeed) {
      unawaited(_restoreHoldSpeed());
    }
  }

  Future<void> _restoreHoldSpeed() async {
    if (_isHoldingSpeed ||
        _holdOriginalRate == null ||
        _restoringHoldSpeed) {
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

  void _beginScrub(double position, {bool revealControls = true}) {
    if (!store.playback.value.canControl || store.playerLocked) return;
    _scrubRevision++;
    _activelyScrubbing = true;
    _scrubDocument = store.operation.id;
    _scrubPosition.value = position.clamp(0.0, store.playback.value.duration);
    if (revealControls) {
      _revealControls();
    } else if (_controlsVisible.value) {
      _hideTimer?.cancel();
    }
  }

  void _updateScrub(double position) {
    if (_scrubPosition.value == null) {
      _beginScrub(position);
      return;
    }
    if (_scrubDocument != store.operation.id ||
        !store.playback.value.canControl ||
        store.playerLocked) {
      _cancelScrub();
      return;
    }
    _scrubPosition.value = position.clamp(0.0, store.playback.value.duration);
  }

  Future<void> _commitScrub() async {
    final target = _scrubPosition.value;
    _activelyScrubbing = false;
    if (target == null) return;
    if (_scrubDocument != store.operation.id ||
        !store.playback.value.canControl ||
        store.playerLocked) {
      _cancelScrub();
      return;
    }
    final revision = _scrubRevision;
    _swipeViewport = null;
    if (_swipeStart.value != null) _swipeStart.value = null;
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
    _apronScrubbing = false;
    _activelyScrubbing = false;
    if (_scrubPosition.value == null && _swipeStart.value == null) return;
    _scrubRevision++;
    _scrubDocument = null;
    _swipeViewport = null;
    _swipeStart.value = null;
    _scrubPosition.value = null;
    if (_controlsVisible.value) _revealControls();
  }

  double? _sliderPositionForGlobalX(
    double globalX, {
    required double thumbRadius,
  }) {
    final box = _fullscreenSliderKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final trackWidth = box.size.width - thumbRadius * 2;
    if (trackWidth <= 0) return null;
    final localX = box.globalToLocal(Offset(globalX, 0)).dx;
    final raw = ((localX - thumbRadius) / trackWidth).clamp(0.0, 1.0);
    final normalized = Directionality.of(context) == TextDirection.rtl
        ? 1.0 - raw
        : raw;
    return normalized * store.playback.value.duration;
  }

  void _startScrubberApron(DragStartDetails details, double thumbRadius) {
    final target = _sliderPositionForGlobalX(
      details.globalPosition.dx,
      thumbRadius: thumbRadius,
    );
    if (target == null) return;
    _apronScrubbing = true;
    _beginScrub(target);
  }

  void _updateScrubberApron(DragUpdateDetails details, double thumbRadius) {
    if (!_apronScrubbing) return;
    final target = _sliderPositionForGlobalX(
      details.globalPosition.dx,
      thumbRadius: thumbRadius,
    );
    if (target != null) _updateScrub(target);
  }

  void _endScrubberApron(DragEndDetails details) {
    if (!_apronScrubbing) return;
    _apronScrubbing = false;
    unawaited(_commitScrub());
  }

  void _cancelScrubberApron() {
    if (!_apronScrubbing) return;
    _cancelScrub();
  }

  void _startSwipe(DragStartDetails details) {
    if (!_canSwipeSeek || _activelyScrubbing) return;
    final surface = _videoSurfaceKey.currentContext?.findRenderObject();
    if (surface is! RenderBox || !surface.hasSize || surface.size.width <= 0) {
      return;
    }
    // DragStartBehavior.down reports where the finger landed. Ignore the top
    // screen strip so a pull-down for the system panel is never read as a seek.
    if (details.globalPosition.dy <
        MediaQuery.paddingOf(context).top + _topSeekExemptHeight) {
      return;
    }
    final state = store.playback.value;
    final startPosition = (_scrubPosition.value ?? state.position).clamp(
      0.0,
      state.duration,
    );
    _swipeLastX = details.globalPosition.dx;
    _swipeViewport = MediaQuery.sizeOf(context);
    // One video width moves at most two minutes, regardless of episode length.
    // Keep fractional seconds so small reversals can refine the target.
    _swipeSecondsPerPixel =
        state.duration.clamp(0.0, 120.0) / surface.size.width;
    _beginScrub(startPosition, revealControls: false);
    _swipeStart.value = startPosition;
  }

  void _updateSwipe(DragUpdateDetails details) {
    if (_swipeStart.value == null) return;
    if (!_canSwipeSeek) {
      _cancelScrub();
      return;
    }
    final distance = details.globalPosition.dx - _swipeLastX;
    _swipeLastX = details.globalPosition.dx;
    final current = _scrubPosition.value;
    if (current == null) return;
    _updateScrub(current + distance * _swipeSecondsPerPixel);
  }

  void _endSwipe(DragEndDetails details) {
    if (_swipeStart.value == null) return;
    if (_canSwipeSeek) {
      unawaited(_commitScrub());
    } else {
      _cancelScrub();
    }
  }

  void _cancelSwipe() {
    if (_swipeStart.value != null) _cancelScrub();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isTablet = AppLayout.of(context).isTablet;
    _syncFullscreen();
    if (_isHoldingSpeed && _holdViewport != MediaQuery.sizeOf(context)) {
      _stopHoldSpeed();
    }
    if (_swipeStart.value != null &&
        _swipeViewport != MediaQuery.sizeOf(context)) {
      _cancelScrub();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stopHoldSpeed();
    } else if (!_isHoldingSpeed &&
        _holdOriginalRate != null &&
        !_restoringHoldSpeed) {
      unawaited(_restoreHoldSpeed());
    }
  }

  Future<void> _screenMode(bool expanded) async {
    await SystemChrome.setPreferredOrientations(
      expanded && !_isTablet
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
    _toggleFlashTimer?.cancel();
    _chromeState.dispose();
    _scrubPosition.dispose();
    _controlsVisible.dispose();
    _holdingSpeed.dispose();
    _swipeStart.dispose();
    _toggleFlashIcon.dispose();
    _opSkipVideoId.dispose();
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
    final safe = MediaQuery.paddingOf(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 820);
    final mediaPad = layout.isCompact
        ? EdgeInsets.only(
            left: math.max(12.0, safe.left + 8.0),
            right: math.max(12.0, safe.right + 8.0),
          )
        : hPad;
    final barPad = layout.useSplitPlayer
        ? layout.pageHorizontalPadding(maxWidth: 1380)
        : hPad;
    return GlassScaffold(
      key: const ValueKey('native-player-page'),
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: Text(
          store.t('nowPlaying'),
          style: const TextStyle(fontSize: 17),
        ),
        padding: layout.appBarPadding(barPad),
        actions: [
          GlassIconButton(
            semanticLabel: store.t('close'),
            icon: const Icon(CupertinoIcons.xmark),
            onPressed: store.closeBrowser,
          ),
        ],
      ),
      body: layout.useSplitPlayer
          ? _splitTheaterBody(context, layout)
          : CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                _inlinePlayer(
                  context,
                  mediaPad,
                  compactPhone: layout.isCompact,
                ),
                SliverPadding(
                  padding: EdgeInsets.only(bottom: safe.bottom + 40),
                  sliver: SliverToBoxAdapter(
                    child: _playbackDetails(
                      context,
                      mediaPad: mediaPad,
                      contentPad: hPad,
                    ),
                  ),
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
          final maxVideoHeight = math.max(200.0, bounds.maxHeight - 150.0);
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
                              ClipRSuperellipse(
                                borderRadius: BorderRadius.circular(24),
                                child: AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: _surface(),
                                ),
                              ),
                              ListenableBuilder(
                                listenable: _surfaceHudListenable,
                                builder: (context, child) {
                                  final chrome = _chromeState.value;
                                  return chrome.canOperate
                                      ? Padding(
                                          padding: const EdgeInsets.only(
                                            top: 10,
                                          ),
                                          child: _controls(
                                            chrome: chrome,
                                            fullscreen: false,
                                            compactInline: true,
                                          ),
                                        )
                                      : const SizedBox.shrink();
                                },
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

  Widget _inlinePlayer(
    BuildContext context,
    EdgeInsets mediaPad, {
    required bool compactPhone,
  }) {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final media = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final topGap = compactPhone ? 54.0 : 60.0;
    final contentWidth = math.max(
      0.0,
      media.width - mediaPad.left - mediaPad.right,
    );
    final estimatedHeaderHeight = safe.top + topGap + contentWidth / (16 / 9);
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
          padding: EdgeInsets.fromLTRB(
            mediaPad.left,
            safe.top + topGap,
            mediaPad.right,
            0,
          ),
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(compactPhone ? 20 : 24),
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
    final videoId = store.playingVideoId;
    final episodeLabel = store.playingEpisodeLabel;
    final key = (
      anime,
      detail,
      videoId,
      episodeLabel,
      store.language,
      maxEpisodeColumns,
    );
    if (_companionCacheKey == key && _companionCacheWidget != null) {
      return _companionCacheWidget!;
    }
    final built = RepaintBoundary(
      child: PlayerCompanionSection(
        store: store,
        anime: anime,
        detail: detail,
        playingVideoId: videoId,
        episodeLabel: episodeLabel,
        maxEpisodeColumns: maxEpisodeColumns,
      ),
    );
    _companionCacheKey = key;
    _companionCacheWidget = built;
    return built;
  }

  Widget _playbackDetails(
    BuildContext context, {
    required EdgeInsets mediaPad,
    required EdgeInsets contentPad,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListenableBuilder(
        listenable: _surfaceHudListenable,
        builder: (context, child) {
          final chrome = _chromeState.value;
          return chrome.canOperate
              ? Padding(
                  padding: EdgeInsets.fromLTRB(
                    mediaPad.left,
                    10,
                    mediaPad.right,
                    0,
                  ),
                  child: _controls(chrome: chrome, fullscreen: false),
                )
              : const SizedBox.shrink();
        },
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(contentPad.left, 0, contentPad.right, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _status(),
            const SizedBox(height: 22),
            _titleHeader(context),
            const SizedBox(height: 24),
            _companionDetails(context),
          ],
        ),
      ),
    ],
  );

  String _episodeLabel(String value) => formatEpisodeNumberLabel(store, value);

  Episode? _nextEpisode() {
    final detail = store.playerDetail;
    final currentId = store.playingVideoId;
    if (detail == null || currentId == null || detail.episodes.length < 2) {
      return null;
    }
    final index = detail.episodes.indexWhere((ep) => ep.id == currentId);
    if (index < 0 || index + 1 >= detail.episodes.length) return null;
    return detail.episodes[index + 1];
  }

  Future<void> _showFullscreenEpisodes(BuildContext context) async {
    final detail = store.playerDetail;
    final anime = store.playingAnime;
    if (detail == null || anime == null || detail.episodes.isEmpty) return;
    await _withMenuHold(
      () => showFullscreenEpisodesDialog(
        context: context,
        store: store,
        anime: anime,
        episodes: detail.episodes,
        currentId: store.playingVideoId,
        closeGlass: _overlayActionGlass,
      ),
    );
  }

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
                MediaQuery.orientationOf(context) == Orientation.portrait ||
                AppLayout.of(context).isTablet
            ? () {
                final playback = store.playback.value;
                if (!store.playerLocked && playback.canControl) {
                  final targetPaused = !playback.paused;
                  if (store.playerFullscreen && !_controlsVisible.value) {
                    _silentPauseToggleTarget = targetPaused;
                    _flashToggleIcon(
                      targetPaused
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                    );
                  }
                  store.controlPlayer(targetPaused ? 'pause' : 'play');
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
      ListenableBuilder(
        listenable: _surfaceHudListenable,
        builder: (context, child) {
          final chrome = _chromeState.value;
          final swipeStart = _swipeStart.value;
          final layout = AppLayout.of(context);
          final tablet = layout.isTablet;
          final safe = MediaQuery.paddingOf(context);
          final showLoading =
              !store.browserError &&
              !chrome.ended &&
              (chrome.phase == PlaybackPhase.loading ||
                  (chrome.phase == PlaybackPhase.content && chrome.buffering));
          final showSeekPreview =
              swipeStart != null && _scrubPosition.value != null;
          final nextEpisode = chrome.ended ? _nextEpisode() : null;
          final showCenterControls =
              store.playerFullscreen &&
              chrome.canOperate &&
              !store.playerLocked &&
              !showLoading &&
              !showSeekPreview;
          final minSide = tablet ? 28.0 : (layout.width < 500 ? 14.0 : 20.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              if (!chrome.surfaceReady &&
                  !store.usesNativeHttpPlayback &&
                  chrome.phase != PlaybackPhase.error &&
                  !store.browserError)
                const ColoredBox(color: Colors.black),
              if (chrome.canControl) _gestureSurface(),
              if (store.playerFullscreen && !store.playerLocked)
                ValueListenableBuilder<bool>(
                  valueListenable: _controlsVisible,
                  builder: (context, visible, _) => IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: visible ? 1 : 0,
                      duration: const Duration(milliseconds: 100),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: safe.top + (tablet ? 80 : 72),
                            child: const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0x40000000),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (chrome.canOperate)
                            Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              height: tablet
                                  ? math.max(52.0, safe.bottom + 28.0)
                                  : 36.0,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      Color(0x22000000),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ValueListenableBuilder<bool>(
                valueListenable: _holdingSpeed,
                builder: (context, holding, _) {
                  if (!holding) return const SizedBox.shrink();
                  return Positioned(
                    top: safe.top + 16,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Semantics(
                          liveRegion: true,
                          child: GlassContainer(
                            key: const ValueKey('player-hold-speed-indicator'),
                            useOwnLayer: true,
                            platformViewBackdrop: true,
                            shape: const LiquidRoundedSuperellipse(
                              borderRadius: 22,
                            ),
                            settings: _fullscreenControlGlass,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  CupertinoIcons.forward_fill,
                                  color: Colors.white,
                                  size: 17,
                                ),
                                const SizedBox(width: 7),
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
                  );
                },
              ),
              if (showSeekPreview)
                Center(
                  child: IgnorePointer(
                    child: Semantics(
                      label: store.t('playbackProgress'),
                      child: GlassContainer(
                        key: const ValueKey('player-seek-preview'),
                        useOwnLayer: true,
                        platformViewBackdrop: true,
                        shape: const LiquidRoundedSuperellipse(
                          borderRadius: 24,
                        ),
                        settings: _fullscreenControlGlass,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        child: RepaintBoundary(
                          child: ValueListenableBuilder<double?>(
                            valueListenable: _scrubPosition,
                            builder: (context, scrub, _) {
                              final target = scrub ?? swipeStart;
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    target >= swipeStart
                                        ? CupertinoIcons.forward_fill
                                        : CupertinoIcons.backward_fill,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${formatPlaybackTime(target)} / ${formatPlaybackTime(chrome.duration)}',
                                    key: const ValueKey('player-seek-target'),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 19,
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${target >= swipeStart ? '+' : '−'}'
                                    '${formatPlaybackTime((target - swipeStart).abs())}',
                                    key: const ValueKey('player-seek-offset'),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    key: const ValueKey(
                                      'player-seek-preview-bar',
                                    ),
                                    width: 148,
                                    height: 4,
                                    child: ClipRSuperellipse(
                                      borderRadius: BorderRadius.circular(2),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          const ColoredBox(
                                            color: Color(0x38FFFFFF),
                                          ),
                                          FractionallySizedBox(
                                            alignment: AlignmentDirectional
                                                .centerStart,
                                            widthFactor: chrome.duration > 0
                                                ? (target / chrome.duration)
                                                      .clamp(0.0, 1.0)
                                                : 0.0,
                                            child: const ColoredBox(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (showLoading)
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
                          PlaybackLoadingSpeed(playback: store.playback),
                        ],
                      ),
                    ),
                  ),
                ),
              if (!showLoading && !showSeekPreview)
                ValueListenableBuilder<IconData?>(
                  valueListenable: _toggleFlashIcon,
                  builder: (context, flashIcon, _) {
                    if (flashIcon == null || _controlsVisible.value) {
                      return const SizedBox.shrink();
                    }
                    return Center(
                      child: IgnorePointer(
                        child: GlassContainer(
                          key: const ValueKey('player-toggle-flash'),
                          useOwnLayer: true,
                          platformViewBackdrop: true,
                          width: 64,
                          height: 64,
                          shape: const LiquidOval(),
                          settings: _overlayActionGlass,
                          padding: EdgeInsets.zero,
                          child: Center(
                            child: Icon(
                              flashIcon,
                              color: Colors.white,
                              size: 30,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              if (showCenterControls)
                ValueListenableBuilder<bool>(
                  valueListenable: _controlsVisible,
                  builder: (context, visible, _) {
                    final showEndedNext = nextEpisode != null && visible;
                    return Center(
                      child: IgnorePointer(
                        ignoring: !visible,
                        child: AnimatedOpacity(
                          opacity: visible ? 1 : 0,
                          duration: const Duration(milliseconds: 100),
                          child: Listener(
                            onPointerDown: (_) => _revealControls(),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _centerControls(
                                  chrome,
                                  tablet: tablet,
                                  viewportWidth: layout.width,
                                ),
                                if (showEndedNext) ...[
                                  const SizedBox(height: 16),
                                  _endedNextEpisodePill(nextEpisode),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                )
              else if (!store.playerFullscreen &&
                  nextEpisode != null &&
                  !store.playerLocked &&
                  !showLoading &&
                  !showSeekPreview)
                Center(child: _endedNextEpisodePill(nextEpisode)),
              if (!store.playerFullscreen)
                Positioned(
                  top: 8,
                  right: 8,
                  child: _portraitTopActions(chrome),
                ),
              if (store.playerFullscreen &&
                  chrome.canOperate &&
                  !store.playerLocked)
                ValueListenableBuilder<bool>(
                  valueListenable: _controlsVisible,
                  builder: (context, visible, _) {
                    final visualBottom = tablet
                        ? (safe.bottom > 0
                              ? math.max(14.0, safe.bottom - 6.0)
                              : 14.0)
                        : (safe.bottom > 0
                              ? math.max(8.0, safe.bottom - 13.0)
                              : 8.0);
                    final splitBottom = layout.width >= 440;
                    final topApron = splitBottom ? 6.0 : 10.0;
                    const bottomApron = 4.0;
                    final hitBottom = math.max(0.0, visualBottom - bottomApron);
                    final thumbRadius = tablet ? 6.5 : 5.5;
                    final seekable = chrome.canControl && swipeStart == null;
                    final sideMargin = tablet ? 16.0 : 8.0;
                    final barContent = Listener(
                      onPointerDown: (_) => _revealControls(),
                      onPointerCancel: (_) => _cancelScrubberApron(),
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              key: const ValueKey('player-scrubber-hit-target'),
                              behavior: HitTestBehavior.opaque,
                              onTap: _revealControls,
                              onHorizontalDragStart: seekable
                                  ? (details) => _startScrubberApron(
                                      details,
                                      thumbRadius,
                                    )
                                  : null,
                              onHorizontalDragUpdate: seekable
                                  ? (details) => _updateScrubberApron(
                                      details,
                                      thumbRadius,
                                    )
                                  : null,
                              onHorizontalDragEnd: seekable
                                  ? _endScrubberApron
                                  : null,
                              onHorizontalDragCancel: seekable
                                  ? _cancelScrubberApron
                                  : null,
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.only(
                              top: topApron,
                              bottom: visualBottom - hitBottom,
                            ),
                            child: _controls(
                              chrome: chrome,
                              fullscreen: true,
                              controlsVisible: visible,
                            ),
                          ),
                        ],
                      ),
                    );
                    return Positioned(
                      left: math.max(minSide, safe.left + sideMargin),
                      right: math.max(minSide, safe.right + sideMargin),
                      bottom: hitBottom,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: IgnorePointer(
                          ignoring: !visible,
                          child: AnimatedOpacity(
                            opacity: visible ? 1 : 0,
                            duration: const Duration(milliseconds: 100),
                            child: tablet
                                ? ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 960,
                                    ),
                                    child: barContent,
                                  )
                                : barContent,
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    ],
  );

  void _seekRelative(double deltaSeconds) {
    final playback = store.playback.value;
    final base = _pendingRelativeTarget ?? playback.position;
    final target = (base + deltaSeconds).clamp(0.0, playback.duration);
    _pendingRelativeTarget = target;
    final token = ++_relativeSeekToken;
    unawaited(
      store.controlPlayer('seek', target).whenComplete(() {
        if (token == _relativeSeekToken) {
          _pendingRelativeTarget = null;
        }
      }),
    );
  }

  void _skipOp() {
    if (!mounted || !_canSkipOp) return;
    HapticFeedback.mediumImpact();
    final playback = store.playback.value;
    _opSkipVideoId.value = store.playingVideoId;
    store.notice = store.t('skippedOpHint');
    store.controlPlayer(
      'seek',
      (playback.position + 85).clamp(0, playback.duration),
    );
  }

  Widget _centerControls(
    PlayerChromeState chrome, {
    required bool tablet,
    required double viewportWidth,
  }) {
    final seekable = chrome.canControl && _swipeStart.value == null;
    final narrow = !tablet && viewportWidth < 420;
    final primarySize = tablet ? 68.0 : (narrow ? 56.0 : 64.0);
    final secondarySize = tablet ? 54.0 : (narrow ? 44.0 : 52.0);
    final primaryIcon = tablet ? 32.0 : (narrow ? 26.0 : 30.0);
    final secondaryIcon = tablet ? 25.0 : (narrow ? 20.0 : 24.0);
    final gap = tablet ? 40.0 : (narrow ? 20.0 : 36.0);
    return Row(
      key: const ValueKey('player-center-controls'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _centerGlassControl(
          CupertinoIcons.gobackward_10,
          'rewindTen',
          seekable ? () => _seekRelative(-10) : null,
          size: secondarySize,
          iconSize: secondaryIcon,
        ),
        SizedBox(width: gap),
        _centerGlassControl(
          chrome.paused ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill,
          chrome.paused ? 'resumePlayback' : 'pausePlayback',
          () => store.controlPlayer(chrome.paused ? 'play' : 'pause'),
          size: primarySize,
          iconSize: primaryIcon,
        ),
        SizedBox(width: gap),
        _centerGlassControl(
          CupertinoIcons.goforward_10,
          'forwardTen',
          seekable ? () => _seekRelative(10) : null,
          size: secondarySize,
          iconSize: secondaryIcon,
          onLongPress: seekable && chrome.inOpWindow && _canSkipOp
              ? _skipOp
              : null,
        ),
      ],
    );
  }

  Widget _centerGlassControl(
    IconData icon,
    String label,
    VoidCallback? action, {
    required double size,
    required double iconSize,
    VoidCallback? onLongPress,
  }) => GlassContainer(
    useOwnLayer: true,
    platformViewBackdrop: true,
    width: size,
    height: size,
    shape: const LiquidOval(),
    settings: _overlayActionGlass,
    padding: EdgeInsets.zero,
    child: _control(
      icon,
      label,
      action,
      Colors.white,
      size: iconSize,
      minimumSize: size,
      onLongPress: onLongPress,
    ),
  );

  Widget _endedNextEpisodePill(Episode episode) {
    final anime = store.playingAnime!;
    return GlassActionPill(
      key: const ValueKey('player-ended-next-episode'),
      useOwnLayer: true,
      platformViewBackdrop: true,
      settings: _fullscreenControlGlass,
      foregroundColor: Colors.white,
      height: 42,
      fontSize: 13.5,
      horizontalPadding: 18,
      icon: CupertinoIcons.forward_end_fill,
      label:
          '${store.t('playNextEpisode')} · ${_episodeLabel(episode.label)}',
      onTap: () => store.play(anime, episode: episode),
    );
  }

  Widget _portraitTopActions(PlayerChromeState chrome) {
    const capsuleHeight = 40.0;
    const slotWidth = 38.0;
    const iconSize = 18.5;
    return ValueListenableBuilder(
      valueListenable: store.danmakuSettingsNotifier,
      builder: (context, danmakuSettings, _) {
        final enabled = danmakuSettings.enabled;
        return GlassContainer(
          key: const ValueKey('player-portrait-actions-capsule'),
          useOwnLayer: true,
          platformViewBackdrop: true,
          shape: const LiquidRoundedSuperellipse(
            borderRadius: capsuleHeight / 2,
          ),
          settings: _overlayActionGlass,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!chrome.canOperate)
                _capsuleAction(
                  CupertinoIcons.arrow_up_left_arrow_down_right,
                  'fullScreen',
                  () => store.setPlayerFullscreen(true),
                  width: slotWidth,
                  height: capsuleHeight,
                  iconSize: iconSize,
                ),
              if (widget.onEnterPictureInPicture != null &&
                  chrome.canControl &&
                  !chrome.ended)
                Semantics(
                  label: store.t('pictureInPicture'),
                  button: true,
                  child: CupertinoButton(
                    key: const ValueKey('player-picture-in-picture'),
                    minimumSize: const Size(slotWidth, capsuleHeight),
                    padding: EdgeInsets.zero,
                    onPressed: () => unawaited(_enterPictureInPicture()),
                    child: const PipIcon(size: iconSize, color: Colors.white),
                  ),
                ),
              if (enabled)
                _capsuleAction(
                  CupertinoIcons.paperplane,
                  'sendDanmaku',
                  () => unawaited(
                    _withMenuHold(() => showDanmakuComposer(context, store)),
                  ),
                  key: const ValueKey('player-danmaku-send'),
                  width: slotWidth,
                  height: capsuleHeight,
                  iconSize: iconSize,
                ),
              _capsuleAction(
                enabled
                    ? CupertinoIcons.text_bubble_fill
                    : CupertinoIcons.text_bubble,
                enabled ? 'hideDanmaku' : 'showDanmaku',
                () => store.setDanmakuSettings(
                  danmakuSettings.copyWith(enabled: !enabled),
                ),
                key: const ValueKey('player-danmaku-button'),
                width: slotWidth,
                height: capsuleHeight,
                iconSize: iconSize,
                color: enabled ? Colors.white : Colors.white54,
              ),
              _settingsButton(
                chrome: chrome,
                fullscreen: false,
                capsuleSlotWidth: slotWidth,
                capsuleSlotHeight: capsuleHeight,
                capsuleIconSize: 19.5,
              ),
            ],
          ),
        );
      },
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
    await showGlassMessageDialog(
      context: context,
      title: store.t('pictureInPicture'),
      message: store.t('pictureInPictureUnavailable'),
      closeLabel: store.t('close'),
    );
  }

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
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: GlassActionPill(
                label: store.t('officialVerification'),
                onTap: store.openOfficial,
              ),
            ),
          if (chrome.phase == PlaybackPhase.error)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: GlassActionPill(
                label: store.t('retry'),
                onTap: store.retryPlayback,
              ),
            ),
        ],
      );
    },
  );

  Widget _controls({
    required PlayerChromeState chrome,
    required bool fullscreen,
    bool controlsVisible = true,
    bool compactInline = false,
  }) {
    final seekable = chrome.canControl && _swipeStart.value == null;
    final active = !fullscreen || controlsVisible;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = fullscreen || dark ? Colors.white : const Color(0xff1c1c1e);
    if (fullscreen) {
      final layout = AppLayout.of(context);
      final tablet = layout.isTablet;
      final splitBottom = layout.width >= 440;
      final hasEpisodes = (store.playerDetail?.episodes.length ?? 0) > 1;
      final thumbRadius = tablet ? 6.5 : 5.5;
      final scrubberHeight = thumbRadius * 2 + 16;
      if (!splitBottom) {
        final timeStyle = TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        return GlassContainer(
          key: const ValueKey('video-glass-controls'),
          useOwnLayer: true,
          platformViewBackdrop: true,
          shape: const LiquidRoundedSuperellipse(borderRadius: 16),
          settings: _fullscreenWingGlass,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 2, right: 6),
                child: PlaybackTimeText(
                  playback: store.playback,
                  active: active,
                  scrub: _scrubPosition,
                  format: PlaybackTimeFormat.position,
                  style: timeStyle,
                ),
              ),
              Expanded(
                child: PlaybackProgressBar(
                  key: _fullscreenSliderKey,
                  playback: store.playback,
                  active: active,
                  seekable: seekable,
                  thumbRadius: thumbRadius,
                  color: color,
                  label: store.t('playbackProgress'),
                  scrub: _scrubPosition,
                  onBeginScrub: _beginScrub,
                  onUpdateScrub: _updateScrub,
                  onCommitScrub: () => unawaited(_commitScrub()),
                  onCancelScrub: _cancelScrub,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 4),
                child: PlaybackTimeText(
                  playback: store.playback,
                  active: active,
                  scrub: _scrubPosition,
                  format: PlaybackTimeFormat.duration,
                  style: timeStyle.copyWith(color: color.withValues(alpha: .76)),
                ),
              ),
              _capsuleAction(
                chrome.muted
                    ? CupertinoIcons.speaker_slash_fill
                    : CupertinoIcons.speaker_2_fill,
                chrome.muted ? 'unmutePlayback' : 'mutePlayback',
                () => store.controlPlayer('mute'),
                key: const ValueKey('player-mute-button'),
                width: 30,
                height: 30,
                iconSize: 16.5,
              ),
              if (hasEpisodes)
                _capsuleAction(
                  CupertinoIcons.list_bullet,
                  'episodes',
                  () => unawaited(_showFullscreenEpisodes(context)),
                  key: const ValueKey('player-fullscreen-episodes'),
                  width: 30,
                  height: 30,
                  iconSize: 16.5,
                ),
            ],
          ),
        );
      }

      final wingHeight = tablet ? 40.0 : 38.0;
      final wingSlotWidth = tablet ? 36.0 : 34.0;
      final wingIconSize = tablet ? 19.5 : 18.5;
      final wingGap = tablet ? 12.0 : 10.0;
      final timeStyle = TextStyle(
        color: color,
        fontSize: tablet ? 13.5 : 13.0,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      return Row(
        key: const ValueKey('video-glass-controls'),
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GlassContainer(
            key: const ValueKey('player-bottom-left-wing'),
            useOwnLayer: true,
            platformViewBackdrop: true,
            height: wingHeight,
            shape: LiquidRoundedSuperellipse(borderRadius: wingHeight / 2),
            settings: _fullscreenWingGlass,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Center(
              child: PlaybackTimeText(
                playback: store.playback,
                active: active,
                scrub: _scrubPosition,
                format: PlaybackTimeFormat.position,
                style: timeStyle,
              ),
            ),
          ),
          SizedBox(width: wingGap),
          Expanded(
            child: GlassContainer(
              key: const ValueKey('player-fullscreen-scrubber'),
              useOwnLayer: true,
              platformViewBackdrop: true,
              shape: LiquidRoundedSuperellipse(
                borderRadius: scrubberHeight / 2,
              ),
              settings: _fullscreenScrubberGlass,
              padding: EdgeInsets.symmetric(horizontal: tablet ? 14 : 12),
              child: PlaybackProgressBar(
                key: _fullscreenSliderKey,
                playback: store.playback,
                active: active,
                seekable: seekable,
                thumbRadius: thumbRadius,
                color: color,
                label: store.t('playbackProgress'),
                scrub: _scrubPosition,
                onBeginScrub: _beginScrub,
                onUpdateScrub: _updateScrub,
                onCommitScrub: () => unawaited(_commitScrub()),
                onCancelScrub: _cancelScrub,
              ),
            ),
          ),
          SizedBox(width: wingGap),
          GlassContainer(
            key: const ValueKey('player-bottom-right-wing'),
            useOwnLayer: true,
            platformViewBackdrop: true,
            height: wingHeight,
            shape: LiquidRoundedSuperellipse(borderRadius: wingHeight / 2),
            settings: _fullscreenWingGlass,
            padding: const EdgeInsets.only(left: 13, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlaybackTimeText(
                  playback: store.playback,
                  active: active,
                  scrub: _scrubPosition,
                  format: PlaybackTimeFormat.duration,
                  style: timeStyle.copyWith(color: color.withValues(alpha: .76)),
                ),
                const SizedBox(width: 8),
                const SizedBox(
                  width: 1,
                  height: 16,
                  child: ColoredBox(color: Color(0x33FFFFFF)),
                ),
                const SizedBox(width: 2),
                _capsuleAction(
                  chrome.muted
                      ? CupertinoIcons.speaker_slash_fill
                      : CupertinoIcons.speaker_2_fill,
                  chrome.muted ? 'unmutePlayback' : 'mutePlayback',
                  () => store.controlPlayer('mute'),
                  key: const ValueKey('player-mute-button'),
                  width: wingSlotWidth,
                  height: wingHeight,
                  iconSize: wingIconSize,
                ),
                if (hasEpisodes)
                  _capsuleAction(
                    CupertinoIcons.list_bullet,
                    'episodes',
                    () => unawaited(_showFullscreenEpisodes(context)),
                    key: const ValueKey('player-fullscreen-episodes'),
                    width: wingSlotWidth,
                    height: wingHeight,
                    iconSize: wingIconSize,
                  ),
              ],
            ),
          ),
        ],
      );
    }

    final compact = compactInline || MediaQuery.sizeOf(context).width < 360;
    final buttonSize = compactInline ? 40.0 : (compact ? 42.0 : 44.0);
    final timeStyle = TextStyle(
      color: color,
      fontSize: compactInline ? 11.5 : (compact ? 12.0 : 12.5),
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final settings = dark
        ? _portraitControlGlassDark
        : _portraitControlGlassLight;
    return GlassContainer(
      key: const ValueKey('video-glass-controls'),
      useOwnLayer: true,
      platformViewBackdrop: false,
      shape: LiquidRoundedSuperellipse(borderRadius: compactInline ? 20 : 22),
      settings: settings,
      padding: EdgeInsets.symmetric(
        horizontal: compactInline ? 12 : 14,
        vertical: compactInline ? 8 : 9,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              PlaybackTimeText(
                playback: store.playback,
                active: active,
                scrub: _scrubPosition,
                format: PlaybackTimeFormat.position,
                style: timeStyle,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PlaybackProgressBar(
                  playback: store.playback,
                  active: active,
                  seekable: seekable,
                  thumbRadius: compactInline ? 6.5 : 7.5,
                  color: color,
                  label: store.t('playbackProgress'),
                  scrub: _scrubPosition,
                  onBeginScrub: _beginScrub,
                  onUpdateScrub: _updateScrub,
                  onCommitScrub: () => unawaited(_commitScrub()),
                  onCancelScrub: _cancelScrub,
                ),
              ),
              const SizedBox(width: 10),
              PlaybackTimeText(
                playback: store.playback,
                active: active,
                scrub: _scrubPosition,
                format: PlaybackTimeFormat.duration,
                style: timeStyle.copyWith(color: color.withValues(alpha: .62)),
              ),
            ],
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
                size: compactInline ? 24 : 27,
                minimumSize: buttonSize,
              ),
              SizedBox(width: compact ? 2 : 4),
              _control(
                CupertinoIcons.gobackward_10,
                'rewindTen',
                seekable ? () => _seekRelative(-10) : null,
                color,
                size: compactInline ? 21 : 24,
                minimumSize: buttonSize,
              ),
              SizedBox(width: compact ? 2 : 4),
              _control(
                CupertinoIcons.goforward_10,
                'forwardTen',
                seekable ? () => _seekRelative(10) : null,
                color,
                size: compactInline ? 21 : 24,
                minimumSize: buttonSize,
                onLongPress: seekable && chrome.inOpWindow && _canSkipOp
                    ? _skipOp
                    : null,
              ),
              const Spacer(),
              _control(
                chrome.muted
                    ? CupertinoIcons.speaker_slash_fill
                    : CupertinoIcons.speaker_2_fill,
                chrome.muted ? 'unmutePlayback' : 'mutePlayback',
                () => store.controlPlayer('mute'),
                color,
                size: compactInline ? 20 : 23,
                minimumSize: buttonSize,
              ),
              SizedBox(width: compact ? 2 : 4),
              _control(
                CupertinoIcons.arrow_up_left_arrow_down_right,
                'fullScreen',
                () => store.setPlayerFullscreen(true),
                color,
                size: compactInline ? 20 : 22,
                minimumSize: buttonSize,
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

  Widget _settingsButton({
    required PlayerChromeState chrome,
    required bool fullscreen,
    double? capsuleSlotWidth,
    double? capsuleSlotHeight,
    double? capsuleIconSize,
  }) {
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
          onTap: () => unawaited(
            _withMenuHold(() => showDanmakuPanel(context, store)),
          ),
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
    return Semantics(
      label: store.t('playbackSettings'),
      button: true,
      child: GlassSettingsMenu(
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
        triggerBuilder: (context, toggleMenu) => ExcludeSemantics(
          child: CupertinoButton(
            minimumSize: Size(capsuleSlotWidth ?? 34, capsuleSlotHeight ?? 36),
            padding: EdgeInsets.zero,
            onPressed: toggleMenu,
            child: Icon(
              CupertinoIcons.ellipsis,
              color: Colors.white,
              size: capsuleIconSize ?? 18,
            ),
          ),
        ),
      ),
    );
  }

  Widget _capsuleAction(
    IconData icon,
    String label,
    VoidCallback action, {
    required double width,
    required double height,
    required double iconSize,
    Color color = Colors.white,
    Key? key,
  }) => Semantics(
    label: store.t(label),
    button: true,
    child: CupertinoButton(
      key: key,
      minimumSize: Size(width, height),
      padding: EdgeInsets.zero,
      onPressed: action,
      child: Icon(icon, color: color, size: iconSize),
    ),
  );

  Widget _fullscreenTopActions({
    required bool tablet,
    required bool narrow,
  }) {
    final capsuleHeight = narrow ? 38.0 : 44.0;
    final slotWidth = narrow ? 34.0 : 42.0;
    final iconSize = narrow ? 18.0 : 20.0;
    final hasEpisodes = (store.playerDetail?.episodes.length ?? 0) > 1;
    return ValueListenableBuilder(
      valueListenable: _chromeState,
      builder: (context, chrome, child) => ValueListenableBuilder(
        valueListenable: store.danmakuSettingsNotifier,
        builder: (context, danmakuSettings, _) {
          final enabled = danmakuSettings.enabled;
          return GlassContainer(
            key: const ValueKey('player-top-actions-capsule'),
            useOwnLayer: true,
            platformViewBackdrop: true,
            shape: LiquidRoundedSuperellipse(borderRadius: capsuleHeight / 2),
            settings: _overlayActionGlass,
            padding: EdgeInsets.symmetric(horizontal: narrow ? 4 : 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!chrome.canOperate && hasEpisodes)
                  _capsuleAction(
                    CupertinoIcons.list_bullet,
                    'episodes',
                    () => unawaited(_showFullscreenEpisodes(context)),
                    key: const ValueKey('player-fullscreen-episodes'),
                    width: slotWidth,
                    height: capsuleHeight,
                    iconSize: iconSize,
                  ),
                if (widget.onEnterPictureInPicture != null &&
                    chrome.canControl &&
                    !chrome.ended)
                  Semantics(
                    label: store.t('pictureInPicture'),
                    button: true,
                    child: CupertinoButton(
                      key: const ValueKey('player-picture-in-picture'),
                      minimumSize: Size(slotWidth, capsuleHeight),
                      padding: EdgeInsets.zero,
                      onPressed: () => unawaited(_enterPictureInPicture()),
                      child: PipIcon(size: iconSize, color: Colors.white),
                    ),
                  ),
                if (enabled)
                  _capsuleAction(
                    CupertinoIcons.paperplane,
                    'sendDanmaku',
                    () => unawaited(
                      _withMenuHold(() => showDanmakuComposer(context, store)),
                    ),
                    key: const ValueKey('player-danmaku-send'),
                    width: slotWidth,
                    height: capsuleHeight,
                    iconSize: iconSize,
                  ),
                _capsuleAction(
                  enabled
                      ? CupertinoIcons.text_bubble_fill
                      : CupertinoIcons.text_bubble,
                  enabled ? 'hideDanmaku' : 'showDanmaku',
                  () => store.setDanmakuSettings(
                    danmakuSettings.copyWith(enabled: !enabled),
                  ),
                  key: const ValueKey('player-danmaku-button'),
                  width: slotWidth,
                  height: capsuleHeight,
                  iconSize: iconSize,
                  color: enabled ? Colors.white : Colors.white54,
                ),
                _settingsButton(
                  chrome: chrome,
                  fullscreen: true,
                  capsuleSlotWidth: slotWidth,
                  capsuleSlotHeight: capsuleHeight,
                  capsuleIconSize: narrow ? 19 : 21,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _cinema(BuildContext context) {
    final layout = AppLayout.of(context);
    final tablet = layout.isTablet;
    final narrow = !tablet && layout.width < 420;
    final safe = MediaQuery.paddingOf(context);
    final actionSize = narrow ? 38.0 : 44.0;
    final actionIconSize = narrow ? 19.0 : 21.0;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(excluding: store.playerLocked, child: _surface()),
          if (!store.playerLocked)
            Positioned(
              top: safe.top + (tablet ? 14.0 : 12.0),
              left: math.max(
                tablet ? 20.0 : 16.0,
                safe.left + (tablet ? 14.0 : 10.0),
              ),
              right: math.max(
                tablet ? 20.0 : 16.0,
                safe.right + (tablet ? 14.0 : 10.0),
              ),
              child: ValueListenableBuilder<bool>(
                valueListenable: _controlsVisible,
                builder: (context, visible, child) => IgnorePointer(
                  ignoring: !visible,
                  child: AnimatedOpacity(
                    opacity: visible ? 1 : 0,
                    duration: const Duration(milliseconds: 100),
                    child: child,
                  ),
                ),
                child: Listener(
                  onPointerDown: (_) => _revealControls(),
                  child: Row(
                    children: [
                      GlassIconButton(
                        key: const ValueKey('player-fullscreen-close'),
                        size: actionSize,
                        iconSize: actionIconSize,
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
                      SizedBox(width: narrow ? 10 : 14),
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                store.playingEpisodeLabel.isEmpty
                                    ? store.playingAnime!.title
                                    : '${store.playingAnime!.title} · ${_episodeLabel(store.playingEpisodeLabel)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: tablet ? 17 : (narrow ? 15 : 16.5),
                                  shadows: const [Shadow(blurRadius: 8)],
                                ),
                              ),
                            ),
                            ValueListenableBuilder(
                              valueListenable: _chromeState,
                              builder: (context, chrome, _) {
                                if ((chrome.rate - 1.0).abs() < 0.01) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: DecoratedBox(
                                    key: const ValueKey('player-rate-badge'),
                                    decoration: ShapeDecoration(
                                      color: const Color(0x52ffffff),
                                      shape: RoundedSuperellipseBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      child: Text(
                                        _rateLabel(chrome.rate),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: narrow ? 10 : 14),
                      _fullscreenTopActions(tablet: tablet, narrow: narrow),
                    ],
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
            left: math.max(
              tablet ? 20.0 : 16.0,
              safe.left + (tablet ? 14.0 : 10.0),
            ),
            top: 0,
            bottom: 0,
            child: Center(
              child: ValueListenableBuilder(
                valueListenable: _chromeState,
                builder: (context, chrome, child) {
                  if (!store.playerLocked && !chrome.canControl) {
                    return const SizedBox.shrink();
                  }
                  return ValueListenableBuilder<bool>(
                    valueListenable: _controlsVisible,
                    builder: (context, visible, _) => IgnorePointer(
                      ignoring: !visible,
                      child: AnimatedOpacity(
                        opacity: visible ? 1 : 0,
                        duration: const Duration(milliseconds: 100),
                        child: GlassIconButton(
                          key: ValueKey(
                            store.playerLocked
                                ? 'player-unlock'
                                : 'player-lock',
                          ),
                          size: actionSize,
                          iconSize: actionIconSize,
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
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
