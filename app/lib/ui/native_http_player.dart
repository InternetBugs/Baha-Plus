import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/community.dart';
import '../data/app_store.dart';
import '../data/native_http_playback.dart';
import '../data/native_playback.dart';
import '../data/playback_environment.dart';
import 'chrome.dart';
import 'native_http_consent.dart';
import 'native_video_surface.dart';
import 'player_page.dart';

export 'native_http_consent.dart';

class NativeHttpPlayer extends StatelessWidget {
  const NativeHttpPlayer({required this.store, this.environment, super.key});
  final AppStore store;
  final PlaybackEnvironment? environment;

  @override
  Widget build(BuildContext context) {
    final mode = environment?.pictureInPicture;
    if (mode == null) return _page(PictureInPictureMode.unavailable);
    return ValueListenableBuilder(
      valueListenable: mode,
      builder: (context, value, child) => _page(value),
    );
  }

  Widget _page(PictureInPictureMode mode) => PlayerPage(
    key: const ValueKey('app-playback-page'),
    store: store,
    videoOnly:
        mode == PictureInPictureMode.active &&
        defaultTargetPlatform == TargetPlatform.android,
    onEnterPictureInPicture: mode == PictureInPictureMode.available
        ? environment?.enterPictureInPicture
        : null,
    video: _NativeHttpVideoLayer(
      store: store,
      pictureInPicture: mode == PictureInPictureMode.active,
    ),
  );
}

class _NativeHttpVideoLayer extends StatefulWidget {
  const _NativeHttpVideoLayer({
    required this.store,
    required this.pictureInPicture,
  });

  final AppStore store;
  final bool pictureInPicture;

  @override
  State<_NativeHttpVideoLayer> createState() => _NativeHttpVideoLayerState();
}

class _NativeHttpVideoLayerState extends State<_NativeHttpVideoLayer> {
  AppStore get store => widget.store;
  NativeHttpPlayback? _session;
  late var _applicationActive = store.applicationActive;
  late var _language = store.language;
  late var _playerFullscreen = store.playerFullscreen;

  @override
  void initState() {
    super.initState();
    _session = store.nativeHttpPlayback;
    store.addListener(_onStoreChanged);
  }

  @override
  void didUpdateWidget(covariant _NativeHttpVideoLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      _session = store.nativeHttpPlayback;
      _applicationActive = store.applicationActive;
      _language = store.language;
      _playerFullscreen = store.playerFullscreen;
      store.addListener(_onStoreChanged);
    }
  }

  void _onStoreChanged() {
    final nextSession = store.nativeHttpPlayback;
    final nextActive = store.applicationActive;
    final nextLanguage = store.language;
    final nextFullscreen = store.playerFullscreen;
    if (identical(nextSession, _session) &&
        nextActive == _applicationActive &&
        nextLanguage == _language &&
        nextFullscreen == _playerFullscreen) {
      return;
    }
    _session = nextSession;
    _applicationActive = nextActive;
    _language = nextLanguage;
    _playerFullscreen = nextFullscreen;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_onStoreChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) return const ColoredBox(color: Colors.black);
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _NativeHttpVideoSurfaceHost(
            store: store,
            session: session,
            pictureInPicture: widget.pictureInPicture,
          ),
          _NativeHttpSessionOverlays(
            store: store,
            session: session,
            playerFullscreen: _playerFullscreen,
            applicationActive: _applicationActive,
          ),
        ],
      ),
    );
  }
}

/// Hosts [NativeVideoSurface] and rebuilds only when the underlying [player],
/// [danmaku] list, or [AppStore.danmakuSettingsNotifier] actually changes —
/// keeping ad countdown ticks from rebuilding the video/danmaku subtree.
class _NativeHttpVideoSurfaceHost extends StatefulWidget {
  const _NativeHttpVideoSurfaceHost({
    required this.store,
    required this.session,
    required this.pictureInPicture,
  });

  final AppStore store;
  final NativeHttpPlayback session;
  final bool pictureInPicture;

  @override
  State<_NativeHttpVideoSurfaceHost> createState() =>
      _NativeHttpVideoSurfaceHostState();
}

class _NativeHttpVideoSurfaceHostState
    extends State<_NativeHttpVideoSurfaceHost> {
  NativePlayback? _player;
  List<NativeDanmaku> _danmaku = const [];
  late DanmakuSettings _settings;

  @override
  void initState() {
    super.initState();
    _syncFromSources();
    widget.session.addListener(_onSessionChanged);
    widget.store.danmakuSettingsNotifier.addListener(_onSettingsChanged);
  }

  void _syncFromSources() {
    _player = widget.session.player;
    _danmaku = widget.session.danmaku;
    _settings = widget.store.danmakuSettingsNotifier.value;
  }

  @override
  void didUpdateWidget(covariant _NativeHttpVideoSurfaceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.danmakuSettingsNotifier.removeListener(
        _onSettingsChanged,
      );
      widget.store.danmakuSettingsNotifier.addListener(_onSettingsChanged);
    }
    _syncFromSources();
  }

  void _onSessionChanged() {
    final nextPlayer = widget.session.player;
    final nextDanmaku = widget.session.danmaku;
    if (identical(nextPlayer, _player) && identical(nextDanmaku, _danmaku)) {
      return;
    }
    _player = nextPlayer;
    _danmaku = nextDanmaku;
    if (mounted) setState(() {});
  }

  void _onSettingsChanged() {
    final next = widget.store.danmakuSettingsNotifier.value;
    if (next == _settings) return;
    _settings = next;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    widget.store.danmakuSettingsNotifier.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (player == null) return const SizedBox.shrink();
    return NativeVideoSurface(
      key: ObjectKey(player),
      playback: player,
      danmaku: _danmaku,
      settings: widget.pictureInPicture
          ? _settings.copyWith(enabled: false)
          : _settings,
      errorLabel: widget.store.t('playerPlaybackError'),
      retryLabel: widget.store.t('retry'),
      onRetry: widget.store.retryPlayback,
      suppressErrors: true,
    );
  }
}

class _NativeHttpSessionOverlays extends StatelessWidget {
  const _NativeHttpSessionOverlays({
    required this.store,
    required this.session,
    required this.playerFullscreen,
    required this.applicationActive,
  });

  final AppStore store;
  final NativeHttpPlayback session;
  final bool playerFullscreen;
  final bool applicationActive;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final player = session.player;
      final showConsent = session.needsConsent;
      final showAdSkip = session.isAdvertisement && player != null;
      final showFailure = session.failureStage != null;
      if (!showConsent && !showAdSkip && !showFailure) {
        return const SizedBox.shrink();
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          if (showConsent)
            NativeHttpPlaybackConsent(
              rating: session.preparation!.rating,
              translate: store.t,
              onConfirm: applicationActive
                  ? () => unawaited(session.consent())
                  : null,
            ),
          if (showAdSkip)
            Builder(
              builder: (context) {
                final safe = MediaQuery.paddingOf(context);
                return Positioned(
                  bottom: playerFullscreen
                      ? math.max(16.0, safe.bottom + 12.0)
                      : 12.0,
                  right: playerFullscreen
                      ? math.max(16.0, safe.right + 12.0)
                      : 12.0,
                  child: AdSkipCapsule(
                    key: const ValueKey('http-skip-ad'),
                    canSkip: session.canSkipAd,
                    label: session.canSkipAd
                        ? store.t('httpSkipAd')
                        : store
                              .t('httpAdCountdown')
                              .replaceAll(
                                '{seconds}',
                                '${session.adSecondsRemaining}',
                              ),
                    onSkip: session.canSkipAd
                        ? () => unawaited(session.skipAd())
                        : null,
                  ),
                );
              },
            ),
          if (showFailure)
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      store.t(switch (session.failureStage) {
                        'parent-verification-required' => 'httpParentRequired',
                        'verification-required' => 'officialVerificationHint',
                        'short-ad-needs-fallback' => 'httpUnsupportedAd',
                        'session-changed' => 'httpSessionChanged',
                        'native-backend-unavailable' => 'httpNativeRequired',
                        'video-id' => 'detailUnavailable',
                        _ => 'playerPlaybackError',
                      }),
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    GlassActionPill(
                      key: const ValueKey('http-playback-retry'),
                      useOwnLayer: true,
                      platformViewBackdrop: true,
                      settings: mediaGlass.copyWith(
                        backerColor: const Color(0x66000000),
                        saturation: 1.0,
                      ),
                      foregroundColor: Colors.white,
                      label: store.t('retry'),
                      onTap: store.retryPlayback,
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

class AdSkipCapsule extends StatefulWidget {
  const AdSkipCapsule({
    required this.canSkip,
    required this.label,
    required this.onSkip,
    super.key,
  });

  final bool canSkip;
  final String label;
  final VoidCallback? onSkip;

  @override
  State<AdSkipCapsule> createState() => _AdSkipCapsuleState();
}

class _AdSkipCapsuleState extends State<AdSkipCapsule> {
  bool _pressed = false;

  static final _countdownGlass = mediaGlass.copyWith(
    backerColor: const Color(0x66000000),
    saturation: 1.0,
  );
  static final _actionGlass = LiquidGlassSettings.ios27Dark.copyWith(
    glassColor: const Color(0x3DFFFFFF),
    backerColor: const Color(0x78101014),
    saturation: 1.1,
  );

  @override
  void didUpdateWidget(covariant AdSkipCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.canSkip && _pressed) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.canSkip && widget.onSkip != null;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: enabled ? widget.onSkip : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: enabled ? widget.onSkip : null,
        child: AnimatedScale(
          scale: !reduceMotion && _pressed ? 0.95 : 1.0,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: GlassContainer(
            useOwnLayer: true,
            platformViewBackdrop: true,
            shape: const LiquidRoundedSuperellipse(borderRadius: 20),
            settings: enabled ? _actionGlass : _countdownGlass,
            padding: EdgeInsets.symmetric(
              horizontal: enabled ? 14 : 13,
              vertical: 8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    color: enabled ? Colors.white : const Color(0xD9FFFFFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    decoration: TextDecoration.none,
                  ),
                ),
                if (enabled) ...[
                  const SizedBox(width: 6),
                  const Icon(
                    CupertinoIcons.forward_end_fill,
                    color: Colors.white,
                    size: 13,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
