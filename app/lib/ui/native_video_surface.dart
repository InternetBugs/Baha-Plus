import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';
import '../core/community.dart';
import '../core/danmaku_animation.dart';
import '../core/native_danmaku.dart';
import '../core/playback_state.dart';
import '../data/native_playback.dart';
import 'chrome.dart';

export '../core/native_danmaku.dart';

class NativeVideoSurface extends StatefulWidget {
  const NativeVideoSurface({
    required this.playback,
    required this.danmaku,
    required this.settings,
    required this.errorLabel,
    required this.retryLabel,
    required this.onRetry,
    this.suppressErrors = false,
    super.key,
  });
  final NativePlayback playback;
  final List<NativeDanmaku> danmaku;
  final DanmakuSettings settings;
  final String errorLabel, retryLabel;
  final VoidCallback onRetry;
  final bool suppressErrors;

  @override
  State<NativeVideoSurface> createState() => NativeVideoSurfaceState();
}

class NativeVideoSurfaceState extends State<NativeVideoSurface>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _position = ValueNotifier<double>(0);
  final _text = <String, TextPainter>{};
  final _retained = <String>{};
  final _activeIds = <String>{};
  final _candidates = <NativeDanmaku>[];
  final _skippedRolling = <String, double>{};
  final _sprites = _DanmakuRasterCache();
  final _lanes = StableDanmakuLanes();
  double _pixelRatio = 1;
  late final DanmakuAnimationClock _animationClock;
  late final Stopwatch _elapsed;
  Timer? _boundaryTimer;
  Duration? _lastPresentedAt;
  Duration? _scheduledBoundaryAt;
  double? _scheduledBoundaryWakePos;
  double? _scheduledBoundaryRate;
  int? _seekRevision;
  List<NativeDanmaku> _enabledItems = const [];
  bool _hadVisibleItems = false;
  // Pace vsync-aligned ticker updates to at most 60 Hz (skipping alternate
  // 120 Hz frames while avoiding 60 Hz Timer/vsync beat judder).
  static const _minFrameGap = Duration(microseconds: 15000);
  static const _diagnostics = bool.fromEnvironment('BAHA_DIAGNOSTICS');
  int? _firstTimedFrame, _lastTimedFrame;
  int _timedFrames = 0, _slowBuilds = 0, _slowRasters = 0;
  int _animatedUpdates = 0;
  int _maxBuildUs = 0, _maxRasterUs = 0;
  VideoPlayerController? _video;
  bool _failed = false;
  int get cachedTextPainters => _text.length;
  int get cachedRasterBytes => _sprites.bytes;
  int get cachedRasterImages => _sprites.length;
  static const maximumTextPainters = 64;
  @visibleForTesting
  double get presentedDanmakuPosition => _position.value;
  @visibleForTesting
  bool get danmakuAnimationActive => _ticker.isActive;

  @override
  void initState() {
    super.initState();
    // The clock must keep time while no engine frames are being requested.
    // Flutter's sampling stopwatch is monotonic and follows fake time in tests.
    _elapsed = WidgetsBinding.instance.samplingClock.stopwatch()..start();
    _animationClock = DanmakuAnimationClock(now: () => _elapsed.elapsed);
    if (_diagnostics) {
      SchedulerBinding.instance.addTimingsCallback(_recordTimings);
    }
    _ticker = createTicker((_) => _presentPosition());
    _updateEnabledItems();
    widget.playback.addListener(_changed);
    _changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ratio = MediaQuery.devicePixelRatioOf(context);
    if (_pixelRatio != ratio) {
      _clearText();
      _pixelRatio = ratio;
    }
  }

  @override
  void didUpdateWidget(covariant NativeVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final playbackChanged = oldWidget.playback != widget.playback;
    final filterChanged =
        oldWidget.danmaku != widget.danmaku ||
        oldWidget.settings.enabled != widget.settings.enabled ||
        oldWidget.settings.rolling != widget.settings.rolling ||
        oldWidget.settings.top != widget.settings.top ||
        oldWidget.settings.bottom != widget.settings.bottom;
    final layoutChanged =
        playbackChanged ||
        !widget.settings.enabled ||
        oldWidget.settings.scale != widget.settings.scale;
    final visualChange =
        playbackChanged ||
        filterChanged ||
        oldWidget.settings != widget.settings;
    if (playbackChanged) {
      oldWidget.playback.removeListener(_changed);
      widget.playback.addListener(_changed);
      _seekRevision = null;
    }
    if (layoutChanged) {
      _clearText();
    }
    if (filterChanged) {
      _updateEnabledItems();
      _cancelBoundaryTimer();
    }
    _syncPlayback(forceRedraw: visualChange);
  }

  void _changed() => _syncPlayback();

  void _syncPlayback({bool forceRedraw = false}) {
    if (!mounted) return;
    final state = widget.playback.state;
    final seekRevision = widget.playback.seekRevision;
    final discontinuity = _seekRevision != seekRevision;
    _seekRevision = seekRevision;
    if (discontinuity) {
      _lanes.clear();
      _skippedRolling.clear();
      _cancelBoundaryTimer();
    }
    final running = !state.paused && !state.buffering;
    _animationClock.update(
      position: state.position,
      rate: state.rate,
      running: running,
      discontinuity: discontinuity,
    );
    _scheduleDrawing(
      forceRedraw: forceRedraw || discontinuity || !running,
      currentState: state,
    );
    final failed = state.phase.name == 'error' && !widget.suppressErrors;
    if (_video != widget.playback.video || _failed != failed) {
      setState(() {
        _video = widget.playback.video;
        _failed = failed;
      });
    }
  }

  void _updateEnabledItems() {
    final settings = widget.settings;
    _enabledItems = !settings.enabled
        ? const []
        : widget.danmaku
              .where((item) {
                return switch (item.mode) {
                  'rolling' => settings.rolling,
                  'top' => settings.top,
                  'bottom' => settings.bottom,
                  _ => false,
                };
              })
              .toList(growable: false);
  }

  void _presentPosition({bool force = false}) {
    final now = _elapsed.elapsed;
    final last = _lastPresentedAt;
    if (!force &&
        last != null &&
        (now - last).inMicroseconds < _minFrameGap.inMicroseconds) {
      return;
    }
    _lastPresentedAt = now;
    final position = math.min(
      widget.playback.duration,
      _animationClock.position,
    );
    if (_position.value != position) {
      _position.value = position;
      if (_diagnostics && _ticker.isActive) _animatedUpdates++;
    }
  }

  void _stopAnimation() {
    if (_ticker.isActive) _ticker.stop();
    _lastPresentedAt = null;
  }

  void _cancelBoundaryTimer() {
    _boundaryTimer?.cancel();
    _boundaryTimer = null;
    _scheduledBoundaryAt = null;
    _scheduledBoundaryWakePos = null;
    _scheduledBoundaryRate = null;
  }

  void _scheduleDrawing({
    bool forceRedraw = false,
    bool atBoundary = false,
    PlaybackState? currentState,
  }) {
    if (atBoundary) _cancelBoundaryTimer();
    final state = currentState ?? widget.playback.state;
    final position = math.min(state.duration, _animationClock.position);
    // Items are sorted by media time, as required by the painter below.
    var low = 0, high = _enabledItems.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_enabledItems[middle].time <= position - 10) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    var visible = false, rolling = false;
    double? nextBoundary, rollingEnd;
    for (var index = low; index < _enabledItems.length; index++) {
      final item = _enabledItems[index];
      if (item.time > position) {
        nextBoundary = math.min(nextBoundary ?? item.time, item.time);
        break;
      }
      final end = item.time + item.duration;
      if (end <= position) continue;
      visible = true;
      if (item.isRolling) {
        rolling = true;
        rollingEnd = math.max(rollingEnd ?? end, end);
      }
      nextBoundary = math.min(nextBoundary ?? end, end);
    }
    // Continuous frames already handle every message entering or leaving.
    // Recheck when current rolling messages end; any messages that started
    // meanwhile can extend that window without extra timer-driven repaints.
    if (rolling) nextBoundary = rollingEnd;
    if (forceRedraw ||
        visible != _hadVisibleItems ||
        (atBoundary && (!rolling || !_ticker.isActive))) {
      _presentPosition(force: true);
    }
    _hadVisibleItems = visible;
    final running =
        !state.paused && !state.buffering && position < state.duration;
    if (running && rolling) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      _stopAnimation();
    }
    if (running && nextBoundary != null) {
      // Static messages only need frames when they appear or disappear.
      // Empty intervals sleep until the next enabled message. Reuse an active
      // timer when the wake target and rate match to avoid 10 Hz timer churn.
      final wakePosition = math.min(nextBoundary, state.duration);
      final delayUs = math.max(
        1000,
        ((wakePosition - position) / state.rate * 1e6).ceil(),
      );
      final desiredAt = _elapsed.elapsed + Duration(microseconds: delayUs);
      final canReuse =
          _boundaryTimer != null &&
          _boundaryTimer!.isActive &&
          _scheduledBoundaryRate == state.rate &&
          _scheduledBoundaryWakePos == wakePosition &&
          _scheduledBoundaryAt != null &&
          (desiredAt - _scheduledBoundaryAt!).inMilliseconds.abs() < 25;
      if (!canReuse) {
        _cancelBoundaryTimer();
        _scheduledBoundaryWakePos = wakePosition;
        _scheduledBoundaryRate = state.rate;
        _scheduledBoundaryAt = desiredAt;
        _boundaryTimer = Timer(Duration(microseconds: delayUs), () {
          if (mounted) _scheduleDrawing(atBoundary: true);
        });
      }
    } else {
      _cancelBoundaryTimer();
    }
  }

  void _clearText() {
    _lanes.clear();
    _retained.clear();
    _activeIds.clear();
    _candidates.clear();
    _skippedRolling.clear();
    _sprites.clear();
    for (final painter in _text.values) {
      painter.dispose();
    }
    _text.clear();
  }

  void _recordTimings(List<ui.FrameTiming> timings) {
    if (!mounted || !_ticker.isActive || widget.playback.isPaused) {
      _resetTimings();
      return;
    }
    for (final timing in timings) {
      final timestamp = timing.timestampInMicroseconds(
        ui.FramePhase.vsyncStart,
      );
      _firstTimedFrame ??= timestamp;
      _lastTimedFrame = timestamp;
      _timedFrames++;
      final build = timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      if (build > 16667) _slowBuilds++;
      if (raster > 16667) _slowRasters++;
      _maxBuildUs = math.max(_maxBuildUs, build);
      _maxRasterUs = math.max(_maxRasterUs, raster);
    }
    if (_firstTimedFrame == null || _lastTimedFrame == null) return;
    final seconds = (_lastTimedFrame! - _firstTimedFrame!) / 1e6;
    if (seconds < 10) return;
    debugPrint(
      '[BAHA_DANMAKU] ${jsonEncode({'frames': _timedFrames, 'windowSeconds': double.parse(seconds.toStringAsFixed(3)), 'fps': double.parse(((_timedFrames - 1) / seconds).toStringAsFixed(2)), 'danmakuUpdates': _animatedUpdates, 'danmakuFps': double.parse((_animatedUpdates / seconds).toStringAsFixed(2)), 'buildOver16ms': _slowBuilds, 'rasterOver16ms': _slowRasters, 'maxBuildMs': _maxBuildUs / 1000, 'maxRasterMs': _maxRasterUs / 1000, 'textPainters': _text.length, 'rasterImages': _sprites.length, 'rasterBytes': _sprites.bytes})}',
    );
    _resetTimings();
  }

  void _resetTimings() {
    _firstTimedFrame = _lastTimedFrame = null;
    _timedFrames = _slowBuilds = _slowRasters = _animatedUpdates = 0;
    _maxBuildUs = _maxRasterUs = 0;
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (_video?.value.isInitialized == true)
          Center(
            child: AspectRatio(
              aspectRatio: _video!.value.aspectRatio,
              child: RepaintBoundary(child: VideoPlayer(_video!)),
            ),
          ),
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              key: const ValueKey('native-danmaku-canvas'),
              painter: _DanmakuPainter(
                position: _position,
                items: _enabledItems,
                settings: widget.settings,
                text: _text,
                lanes: _lanes,
                sprites: _sprites,
                retained: _retained,
                activeIds: _activeIds,
                candidates: _candidates,
                skippedRolling: _skippedRolling,
                pixelRatio: _pixelRatio,
              ),
            ),
          ),
        ),
        if (_failed)
          ColoredBox(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.errorLabel,
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 14),
                  GlassActionPill(
                    useOwnLayer: true,
                    platformViewBackdrop: true,
                    settings: mediaGlass.copyWith(
                      backerColor: const Color(0x66000000),
                      saturation: 1.0,
                    ),
                    foregroundColor: Colors.white,
                    label: widget.retryLabel,
                    onTap: widget.onRetry,
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  @override
  void dispose() {
    widget.playback.removeListener(_changed);
    if (_diagnostics) {
      SchedulerBinding.instance.removeTimingsCallback(_recordTimings);
    }
    _cancelBoundaryTimer();
    _ticker.dispose();
    _elapsed.stop();
    _position.dispose();
    _clearText();
    super.dispose();
  }
}

class _DanmakuSprite {
  _DanmakuSprite(this.image, this.width, this.height, this.bytes)
    : sourceRect = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
  final ui.Image image;
  final Rect sourceRect;
  final double width, height;
  final int bytes;
}

class _DanmakuRasterCache {
  static const maximumBytes = 16 * 1024 * 1024;
  static const padding = 4.0;
  final _images = <String, _DanmakuSprite>{};
  final _unavailable = <String>{};
  int bytes = 0;
  int get length => _images.length;

  _DanmakuSprite? obtain(String id, TextPainter painter, double ratio) {
    final existing = _images[id];
    if (existing != null) return existing;
    if (_unavailable.contains(id)) return null;
    final width = painter.width + padding * 2;
    final height = painter.height + padding * 2;
    final pixelWidth = (width * ratio).ceil();
    final pixelHeight = (height * ratio).ceil();
    final cost = pixelWidth * pixelHeight * 8;
    if (pixelWidth > 4096 ||
        pixelHeight > 1024 ||
        cost > maximumBytes ||
        bytes + cost > maximumBytes) {
      return null;
    }
    ui.Picture? picture;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(ratio);
      painter.paint(canvas, const Offset(padding, padding));
      picture = recorder.endRecording();
      final image = picture.toImageSync(pixelWidth, pixelHeight);
      final sprite = _DanmakuSprite(image, width, height, cost);
      _images[id] = sprite;
      bytes += cost;
      return sprite;
    } catch (_) {
      _unavailable.add(id);
      return null;
    } finally {
      picture?.dispose();
    }
  }

  void remove(String id) {
    final sprite = _images.remove(id);
    if (sprite != null) {
      bytes -= sprite.bytes;
      sprite.image.dispose();
    }
    _unavailable.remove(id);
  }

  void clear() {
    for (final sprite in _images.values) {
      sprite.image.dispose();
    }
    _images.clear();
    _unavailable.clear();
    bytes = 0;
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.position,
    required this.items,
    required this.settings,
    required this.text,
    required this.lanes,
    required this.sprites,
    required this.retained,
    required this.activeIds,
    required this.candidates,
    required this.skippedRolling,
    required this.pixelRatio,
  }) : super(repaint: position);
  final ValueNotifier<double> position;
  final List<NativeDanmaku> items;
  final DanmakuSettings settings;
  final Map<String, TextPainter> text;
  final StableDanmakuLanes lanes;
  final _DanmakuRasterCache sprites;
  final Set<String> retained;
  final Set<String> activeIds;
  final List<NativeDanmaku> candidates;
  final Map<String, double> skippedRolling;
  final double pixelRatio;
  static final _spritePaint = Paint()..filterQuality = FilterQuality.low;
  static final _fallbackOpacityPaint = Paint();

  static TextPainter _createTextPainter(NativeDanmaku item, double scale) =>
      TextPainter(
        text: TextSpan(
          text: item.text,
          style: TextStyle(
            color: item.color,
            fontSize: item.size * scale,
            fontWeight: FontWeight.w600,
            shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

  void _pruneExcept(Set<String> keep) {
    if (text.length <= keep.length) return;
    if (keep.isEmpty) {
      for (final painter in text.values) {
        painter.dispose();
      }
      text.clear();
      sprites.clear();
      return;
    }
    final expired = <String>[
      for (final id in text.keys)
        if (!keep.contains(id)) id,
    ];
    for (var i = 0; i < expired.length; i++) {
      final id = expired[i];
      text.remove(id)!.dispose();
      sprites.remove(id);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    retained.clear();
    activeIds.clear();
    candidates.clear();
    if (settings.enabled && items.isNotEmpty && size.width > 0 && size.height > 0) {
      final now = position.value;
      var low = 0, high = items.length;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (items[middle].time < now - 10) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      var considered = 0;
      for (
        var index = low;
        index < items.length && items[index].time <= now && considered < 256;
        index++
      ) {
        considered++;
        final item = items[index];
        if (now >= item.time + item.duration) continue;
        candidates.add(item);
        activeIds.add(item.id);
      }
      // Evict expired painters and raster sprites before allocating new ones so
      // leaving messages never starve incoming messages of cache budget.
      _pruneExcept(activeIds);
      if (skippedRolling.isNotEmpty) {
        skippedRolling.removeWhere((_, end) => end <= now);
      }
      final lineHeight = 26 * settings.scale;
      final laneCount = math.max(1, (size.height * .65 / lineHeight).floor());
      final previousDecisions = lanes.decisionCount;
      lanes.prepare(position: now, laneCount: laneCount);
      if (lanes.decisionCount == 0 && previousDecisions > 0) {
        skippedRolling.clear();
      }
      final opacity = settings.opacity.clamp(0.0, 1.0);
      _spritePaint.color = Color.fromRGBO(255, 255, 255, opacity);
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      for (
        var index = 0;
        index < candidates.length &&
            retained.length < NativeVideoSurfaceState.maximumTextPainters;
        index++
      ) {
        final item = candidates[index];
        final duration = item.duration;
        final end = item.time + duration;
        final TextPainter painter;
        final int? lane;
        if (item.isRolling) {
          if (skippedRolling.containsKey(item.id)) continue;
          final cached = text[item.id];
          final laidOut =
              cached ?? _createTextPainter(item, settings.scale);
          lane = lanes.assign(
            id: item.id,
            mode: item.mode,
            start: item.time,
            end: end,
            width: laidOut.width,
            viewportWidth: size.width,
          );
          if (lane == null) {
            if (cached == null) laidOut.dispose();
            skippedRolling[item.id] = end;
            continue;
          }
          if (cached == null) text[item.id] = laidOut;
          painter = laidOut;
        } else {
          lane = lanes.assign(
            id: item.id,
            mode: item.mode,
            start: item.time,
            end: end,
          );
          if (lane == null) continue;
          painter = text.putIfAbsent(
            item.id,
            () => _createTextPainter(item, settings.scale),
          );
        }
        retained.add(item.id);
        final progress = (now - item.time) / duration;
        final x = item.isRolling
            ? size.width - progress * (size.width + painter.width)
            : (size.width - painter.width) / 2;
        final y = identical(item.mode, 'bottom') || item.mode == 'bottom'
            ? size.height - (lane + 1) * lineHeight - 5
            : lane * lineHeight + 5;
        final sprite = sprites.obtain(item.id, painter, pixelRatio);
        if (sprite == null) {
          if (opacity < 0.999) {
            _fallbackOpacityPaint.color = Color.fromRGBO(
              255,
              255,
              255,
              opacity,
            );
            canvas.saveLayer(
              Rect.fromLTWH(x - 4, y - 4, painter.width + 8, painter.height + 8),
              _fallbackOpacityPaint,
            );
            painter.paint(canvas, Offset(x, y));
            canvas.restore();
          } else {
            painter.paint(canvas, Offset(x, y));
          }
        } else {
          canvas.drawImageRect(
            sprite.image,
            sprite.sourceRect,
            Rect.fromLTWH(
              x - _DanmakuRasterCache.padding,
              y - _DanmakuRasterCache.padding,
              sprite.width,
              sprite.height,
            ),
            _spritePaint,
          );
        }
      }
      canvas.restore();
    } else {
      lanes.clear();
      skippedRolling.clear();
    }
    _pruneExcept(retained);
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.items != items ||
      oldDelegate.settings != settings ||
      oldDelegate.pixelRatio != pixelRatio;
}
