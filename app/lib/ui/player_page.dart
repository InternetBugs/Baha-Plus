import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/playback_state.dart';
import '../data/app_store.dart';
import 'chrome.dart';

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
  bool _fullscreen = false, _expandedSynopsis = false;
  bool _controlsVisible = true;
  String _controlState = '';
  Timer? _hideTimer;

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
    if (state.phase == PlaybackPhase.content && !state.paused) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _controlsVisible = false);
      });
    }
  }

  void _syncFullscreen() {
    if (_fullscreen == store.playerFullscreen) return;
    _fullscreen = store.playerFullscreen;
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
    builder: (context, child) => _page(context),
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
              SectionHeading(store.t('synopsis')),
              const SizedBox(height: 14),
              Text(
                detail.description,
                maxLines: _expandedSynopsis ? null : 4,
                overflow: _expandedSynopsis
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: TextStyle(
                  color: secondary(context),
                  height: 1.7,
                  fontSize: 14,
                ),
              ),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () =>
                    setState(() => _expandedSynopsis = !_expandedSynopsis),
                child: Text(
                  store.t(_expandedSynopsis ? 'showLess' : 'showMore'),
                  style: const TextStyle(fontSize: 13),
                ),
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

  Widget _surface() => Listener(
    onPointerDown: (_) => _revealControls(),
    child: Stack(
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
                  behavior: HitTestBehavior.opaque,
                  onTap: _revealControls,
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
                      _videoAction(
                        CupertinoIcons.ellipsis,
                        'playbackSettings',
                        _settingsMenu,
                      ),
                    ],
                  ),
                ),
              if (state.canOperate)
                Positioned(
                  left: store.playerFullscreen ? 48 : 8,
                  right: store.playerFullscreen ? 48 : 8,
                  bottom: store.playerFullscreen
                      ? MediaQuery.paddingOf(context).bottom + 18
                      : 8,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 620),
                          child: _controls(),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

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

  Widget _controls() => ValueListenableBuilder(
    valueListenable: store.playback,
    builder: (context, state, child) {
      final seekable = state.canControl;
      final duration = state.duration;
      final position = (_scrub ?? state.position).clamp(0.0, duration);
      const color = Colors.white;
      return GlassContainer(
        key: const ValueKey('video-glass-controls'),
        useOwnLayer: true,
        platformViewBackdrop: true,
        shape: const LiquidRoundedSuperellipse(borderRadius: 22),
        settings: LiquidGlassSettings.ios27Dark.copyWith(
          backerColor: const Color(0x88101014),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 24,
              child: Semantics(
                label: store.t('playbackProgress'),
                child: GlassSlider(
                  value: position,
                  max: duration > 0 ? duration : 1,
                  thumbRadius: 6,
                  trackHeight: 3,
                  activeColor: Colors.white,
                  inactiveColor: const Color(0x55ffffff),
                  onChanged: seekable
                      ? (value) => setState(() => _scrub = value)
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
                  size: 23,
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
                  size: 21,
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
                  size: 21,
                ),
                Expanded(
                  child: Text(
                    '${_time(position)} / ${_time(duration)}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontFeatures: [FontFeature.tabularFigures()],
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
                  size: 20,
                ),
                _control(
                  store.playerFullscreen
                      ? CupertinoIcons.arrow_down_right_arrow_up_left
                      : CupertinoIcons.arrow_up_left_arrow_down_right,
                  store.playerFullscreen ? 'exitFullScreen' : 'fullScreen',
                  () => store.setPlayerFullscreen(!store.playerFullscreen),
                  color,
                  size: 18,
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
  }) => Semantics(
    label: store.t(label),
    button: true,
    child: CupertinoButton(
      minimumSize: const Size(36, 36),
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
                store.controlPlayer('danmaku', state.danmaku ? 0 : 1);
              },
              child: Text(
                store.t(state.danmaku ? 'hideDanmaku' : 'showDanmaku'),
              ),
            ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              store.reloadBrowser();
            },
            child: Text(store.t('refresh')),
          ),
          CupertinoActionSheetAction(
            onPressed: () async {
              Navigator.pop(sheet);
              await store.controlPlayer('pause');
              await store.connectAccount();
            },
            child: Text(store.t('connectAccount')),
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
          child: Row(
            children: [
              GlassIconButton(
                useOwnLayer: true,
                platformViewBackdrop: true,
                settings: mediaGlass.copyWith(
                  backerColor: const Color(0x66000000),
                ),
                semanticLabel: store.t('exitFullScreen'),
                onPressed: () => store.setPlayerFullscreen(false),
                icon: const Icon(CupertinoIcons.xmark, color: Colors.white),
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
              GlassIconButton(
                useOwnLayer: true,
                platformViewBackdrop: true,
                settings: mediaGlass.copyWith(
                  backerColor: const Color(0x66000000),
                ),
                semanticLabel: store.t('playbackSettings'),
                onPressed: _settingsMenu,
                icon: const Icon(CupertinoIcons.ellipsis, color: Colors.white),
              ),
            ],
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
