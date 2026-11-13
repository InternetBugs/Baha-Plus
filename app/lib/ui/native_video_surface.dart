import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';
import '../core/community.dart';
import '../core/danmaku_animation.dart';
import '../core/native_danmaku.dart';
import '../data/native_playback.dart';

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
  final _sprites = _DanmakuRasterCache();
  final _lanes = StableDanmakuLanes();
  double _pixelRatio = 1;
  late final DanmakuAnimationClock _animationClock;
  late final Stopwatch _elapsed;
  Timer? _frameTimer, _boundaryTimer;
  Duration? _lastPresentedAt;
  int? _seekRevision;
  List<NativeDanmaku> _enabledItems = const [];
  bool _hadVisibleItems = false;
  // Request a single engine frame per interval instead of keeping a ticker
  // scheduling frames at the display's (potentially 120 Hz) refresh rate.
  static const _frameInterval = Duration(microseconds: 16667);
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
  bool get danmakuAnimationActive => _frameTimer != null;

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
    _ticker = createTicker((_) {
      _ticker.stop();
      _presentPosition();
    });
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
    final visualChange =
        oldWidget.settings != widget.settings ||
        oldWidget.danmaku != widget.danmaku ||
        oldWidget.playback != widget.playback;
    if (oldWidget.playback != widget.playback) {
      oldWidget.playback.removeListener(_changed);
      widget.playback.addListener(_changed);
      _seekRevision = null;
    }
    if (oldWidget.settings != widget.settings ||
        oldWidget.playback != widget.playback) {
      _clearText();
    }
    if (visualChange) _updateEnabledItems();
    _syncPlayback(forceRedraw: visualChange);
  }

  void _changed() => _syncPlayback();

  void _syncPlayback({bool forceRedraw = false}) {
    if (!mounted) return;
    final state = widget.playback.state;
    final seekRevision = widget.playback.seekRevision;
    final discontinuity = _seekRevision != seekRevision;
    _seekRevision = seekRevision;
    if (discontinuity) _lanes.clear();
    final running = !state.paused && !state.buffering;
    _animationClock.update(
      position: state.position,
      rate: state.rate,
      running: running,
      discontinuity: discontinuity,
    );
    _scheduleDrawing(forceRedraw: forceRedraw || discontinuity || !running);
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
    // Allow one microsecond for integer timestamp rounding at 60/120 Hz.
    if (!force &&
        last != null &&
        (now - last).inMicroseconds < _frameInterval.inMicroseconds - 1) {
      return;
    }
    _lastPresentedAt = now;
    final position = math.min(
      widget.playback.state.duration,
      _animationClock.position,
    );
    if (_position.value != position) {
      _position.value = position;
      if (_diagnostics && _frameTimer != null) _animatedUpdates++;
    }
  }

  void _requestFrame() {
    if (mounted && !_ticker.isActive) _ticker.start();
  }

  void _stopAnimation() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _ticker.stop();
    _lastPresentedAt = null;
  }

  void _scheduleDrawing({bool forceRedraw = false, bool atBoundary = false}) {
    _boundaryTimer?.cancel();
    _boundaryTimer = null;
    final position = math.min(
      widget.playback.state.duration,
      _animationClock.position,
    );
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
      final end = item.time + (item.mode == 'rolling' ? 10 : 5);
      if (end <= position) continue;
      visible = true;
      rolling |= item.mode == 'rolling';
      if (item.mode == 'rolling') {
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
        (atBoundary && (!rolling || _frameTimer == null))) {
      _presentPosition(force: true);
    }
    _hadVisibleItems = visible;
    final state = widget.playback.state;
    final running =
        !state.paused && !state.buffering && position < state.duration;
    if (running && rolling) {
      if (_frameTimer == null) {
        _frameTimer = Timer.periodic(_frameInterval, (_) => _requestFrame());
        _requestFrame();
      }
    } else {
      _stopAnimation();
    }
    if (running && nextBoundary != null) {
      // Static messages only need frames when they appear or disappear.
      // Empty intervals sleep until the next enabled message. Native samples
      // can reschedule this wake when the media clock or playback rate changes.
      final wakePosition = math.min(nextBoundary, state.duration);
      final delayUs = ((wakePosition - position) / state.rate * 1e6).ceil();
      _boundaryTimer = Timer(
        Duration(microseconds: math.max(1000, delayUs)),
        () {
          if (mounted) _scheduleDrawing(atBoundary: true);
        },
      );
    }
  }

  void _clearText() {
    _lanes.clear();
    _sprites.clear();
    for (final painter in _text.values) {
      painter.dispose();
    }
    _text.clear();
  }

  void _recordTimings(List<ui.FrameTiming> timings) {
    if (!mounted || _frameTimer == null || widget.playback.state.paused) {
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
              child: VideoPlayer(_video!),
            ),
          ),
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              key: const ValueKey('native-danmaku-canvas'),
              painter: _DanmakuPainter(
                position: _position,
                items: widget.danmaku,
                settings: widget.settings,
                text: _text,
                lanes: _lanes,
                sprites: _sprites,
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
                  CupertinoButton(
                    onPressed: widget.onRetry,
                    child: Text(widget.retryLabel),
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
    _frameTimer?.cancel();
    _boundaryTimer?.cancel();
    _ticker.dispose();
    _elapsed.stop();
    _position.dispose();
    _clearText();
    super.dispose();
  }
}

class _DanmakuSprite {
  const _DanmakuSprite(this.image, this.width, this.height, this.bytes);
  final ui.Image image;
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

  void retain(Set<String> ids) {
    for (final id in _images.keys.where((id) => !ids.contains(id)).toList()) {
      final sprite = _images.remove(id)!;
      bytes -= sprite.bytes;
      sprite.image.dispose();
    }
    _unavailable.removeWhere((id) => !ids.contains(id));
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
    required this.pixelRatio,
  }) : super(repaint: position);
  final ValueNotifier<double> position;
  final List<NativeDanmaku> items;
  final DanmakuSettings settings;
  final Map<String, TextPainter> text;
  final StableDanmakuLanes lanes;
  final _DanmakuRasterCache sprites;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final retained = <String>{};
    if (settings.enabled && size.width > 0 && size.height > 0) {
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
      final lineHeight = 26 * settings.scale;
      final laneCount = math.max(1, (size.height * .65 / lineHeight).floor());
      lanes.prepare(position: now, laneCount: laneCount);
      var considered = 0;
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      for (
        var index = low;
        index < items.length &&
            items[index].time <= now &&
            retained.length < NativeVideoSurfaceState.maximumTextPainters &&
            considered < 256;
        index++
      ) {
        considered++;
        final item = items[index];
        final duration = item.mode == 'rolling' ? 10.0 : 5.0;
        if (now >= item.time + duration ||
            (item.mode == 'rolling' && !settings.rolling) ||
            (item.mode == 'top' && !settings.top) ||
            (item.mode == 'bottom' && !settings.bottom)) {
          continue;
        }
        final lane = lanes.assign(
          id: item.id,
          mode: item.mode,
          start: item.time,
          end: item.time + duration,
        );
        if (lane == null) continue;
        final painter = text.putIfAbsent(
          item.id,
          () => TextPainter(
            text: TextSpan(
              text: item.text,
              style: TextStyle(
                color: item.color.withValues(alpha: settings.opacity),
                fontSize: item.size * settings.scale,
                fontWeight: FontWeight.w600,
                shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout(),
        );
        retained.add(item.id);
        final progress = (now - item.time) / duration;
        final x = item.mode == 'rolling'
            ? size.width - progress * (size.width + painter.width)
            : (size.width - painter.width) / 2;
        final y = item.mode == 'bottom'
            ? size.height - (lane + 1) * lineHeight - 5
            : lane * lineHeight + 5;
        final sprite = sprites.obtain(item.id, painter, pixelRatio);
        if (sprite == null) {
          painter.paint(canvas, Offset(x, y));
        } else {
          canvas.drawImageRect(
            sprite.image,
            Rect.fromLTWH(
              0,
              0,
              sprite.image.width.toDouble(),
              sprite.image.height.toDouble(),
            ),
            Rect.fromLTWH(
              x - _DanmakuRasterCache.padding,
              y - _DanmakuRasterCache.padding,
              sprite.width,
              sprite.height,
            ),
            Paint()..filterQuality = FilterQuality.low,
          );
        }
      }
      canvas.restore();
    } else {
      lanes.clear();
    }
    for (final id in text.keys.where((id) => !retained.contains(id)).toList()) {
      text.remove(id)!.dispose();
    }
    sprites.retain(retained);
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.items != items ||
      oldDelegate.settings != settings ||
      oldDelegate.pixelRatio != pixelRatio;
}
