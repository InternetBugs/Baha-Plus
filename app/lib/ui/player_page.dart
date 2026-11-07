import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/playback_state.dart';
import '../data/app_store.dart';
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

class _PlayerPageState extends State<PlayerPage> {
  AppStore get store => widget.store;
  double? _scrub;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  String _controlState = '';
  Timer? _hideTimer;
  final _videoSurfaceKey = GlobalKey(debugLabel: 'player-video-surface');

  @override
  void initState() {
    super.initState();
    store.addListener(_syncFullscreen);
    store.playback.addListener(_playbackChanged);
    _syncFullscreen();
    _playbackChanged();
  }

  void _playbackChanged() {
    final state = store.playback.value;
    final key = '${state.phase.name}:${state.paused}';
    if (key == _controlState) return;
    _controlState = key;
    _revealControls();
  }

  void _revealControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    final state = store.playback.value;
    if (store.playerFullscreen &&
        state.phase == PlaybackPhase.content &&
        !state.paused) {
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

  void _dismissOutsideVideo(PointerDownEvent event) {
    final surface = _videoSurfaceKey.currentContext?.findRenderObject();
    if (surface is! RenderBox || !surface.hasSize) return;
    final bounds = Offset.zero & surface.size;
    if (!bounds.contains(surface.globalToLocal(event.position))) {
      _hideControls();
    }
  }

  void _syncFullscreen() {
    if (_fullscreen == store.playerFullscreen) return;
    _fullscreen = store.playerFullscreen;
    _revealControls();
    unawaited(_screenMode(_fullscreen));
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
    store.removeListener(_syncFullscreen);
    store.playback.removeListener(_playbackChanged);
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
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: secondary(context).withValues(alpha: .06),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      for (final item in detail.metadata)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 92,
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
                  ),
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
            if (!state.surfaceReady && !store.browserError)
              const ColoredBox(
                color: Colors.black,
                child: Center(
                  child: CupertinoActivityIndicator(color: Colors.white),
                ),
              ),
            if (state.canControl)
              GestureDetector(
                key: const ValueKey('player-controls-toggle'),
                behavior: HitTestBehavior.opaque,
                onTap: store.playerFullscreen
                    ? _toggleControls
                    : _revealControls,
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
            if (store.playerFullscreen && state.canOperate)
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
                      duration: const Duration(milliseconds: 180),
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
        PlaybackPhase.content => state.buffering ? 'loading' : null,
        PlaybackPhase.age => 'playerAgeHint',
        PlaybackPhase.advertisement => null,
        PlaybackPhase.error => 'playerPlaybackError',
        PlaybackPhase.verification => 'officialVerificationHint',
        PlaybackPhase.official => 'playerConfirmHint',
        PlaybackPhase.loading => 'loading',
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
      final seekable = state.canControl;
      final duration = state.duration;
      final position = (_scrub ?? state.position).clamp(0.0, duration);
      final dark = Theme.of(context).brightness == Brightness.dark;
      final color = fullscreen || dark ? Colors.white : const Color(0xff1c1c1e);
      final compact = !fullscreen && MediaQuery.sizeOf(context).width < 350;
      final settings = fullscreen || dark
          ? LiquidGlassSettings.ios27Dark
          : LiquidGlassSettings.ios27Light;
      return GlassContainer(
        key: const ValueKey('video-glass-controls'),
        useOwnLayer: true,
        platformViewBackdrop: fullscreen,
        shape: LiquidRoundedSuperellipse(borderRadius: fullscreen ? 28 : 22),
        settings: settings.copyWith(
          backerColor: fullscreen
              ? const Color(0x88101014)
              : dark
              ? const Color(0x661c1c1e)
              : const Color(0x66ffffff),
        ),
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
                child: GlassSlider(
                  value: position,
                  max: duration > 0 ? duration : 1,
                  thumbRadius: fullscreen ? 8 : 7,
                  trackHeight: 4,
                  activeColor: color,
                  inactiveColor: color.withValues(alpha: .33),
                  onChanged: seekable
                      ? (value) {
                          _hideTimer?.cancel();
                          setState(() => _scrub = value);
                        }
                      : null,
                  onChangeEnd: (value) {
                    store.controlPlayer('seek', value);
                    setState(() => _scrub = null);
                    _revealControls();
                  },
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

  void _speed(double current) => showCupertinoModalPopup<void>(
    context: context,
    builder: (sheet) => CupertinoActionSheet(
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

  void _settingsMenu() {
    final state = store.playback.value;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(store.t('playbackSettings')),
        actions: [
          if (state.canControl && state.qualities.isNotEmpty)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(sheet);
                _qualityMenu();
              },
              child: Text(
                '${store.t('videoQuality')} · ${state.quality == 0 ? store.t('automaticQuality') : '${state.quality}p'}',
              ),
            ),
          if (state.canControl)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(sheet);
                _speed(state.rate);
              },
              child: Text(store.t('playbackSpeed')),
            ),
          if (state.canControl && state.hasDanmaku)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(sheet);
                showDanmakuPanel(context, store);
              },
              child: Text(store.t('danmakuSettings')),
            ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              store.reloadBrowser();
            },
            child: Text(store.t('refresh')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: Text(store.t('close')),
        ),
      ),
    );
  }

  void _qualityMenu() {
    final state = store.playback.value;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
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
        _surface(),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 14,
          left: 20,
          right: 20,
          child: IgnorePointer(
            ignoring: !_controlsVisible,
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
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
      ],
    ),
  );

  String _time(double seconds) {
    final value = seconds.floor();
    final minutes = value ~/ 60;
    return '${minutes.toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
  }
}
