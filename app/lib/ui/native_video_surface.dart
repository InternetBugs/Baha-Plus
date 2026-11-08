import 'dart:math' as math;
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';
import '../core/community.dart';
import '../core/danmaku_animation.dart';
import '../core/models.dart';
import '../data/native_playback.dart';

class NativeDanmaku {
  NativeDanmaku.fromJson(Json json)
    : id = json['id'] as String,
      text = json['text'] as String,
      mode = json['mode'] as String,
      time = (json['time'] as num).toDouble(),
      size = (json['size'] as num).toDouble(),
      color = parseColor(json['color']) {
    if (!RegExp(r'^\d{1,20}$').hasMatch(id) ||
        text.isEmpty ||
        text.length > 500 ||
        !const ['rolling', 'top', 'bottom'].contains(mode) ||
        !time.isFinite ||
        time < 0 ||
        time > 172800 ||
        !size.isFinite ||
        size < 12 ||
        size > 40 ||
        !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(json['color'] as String)) {
      throw const FormatException('Invalid native danmaku');
    }
  }
  final String id, text, mode;
  final double time, size;
  final Color color;

  static Color parseColor(dynamic value) {
    if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
      throw const FormatException('Invalid native danmaku color');
    }
    return Color(int.parse('ff${value.substring(1)}', radix: 16));
  }
}

class NativeVideoSurface extends StatefulWidget {
  const NativeVideoSurface({
    required this.playback,
    required this.danmaku,
    required this.settings,
    required this.errorLabel,
    required this.retryLabel,
    required this.onRetry,
    super.key,
  });
  final NativePlayback playback;
  final List<NativeDanmaku> danmaku;
  final DanmakuSettings settings;
  final String errorLabel, retryLabel;
  final VoidCallback onRetry;

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
  static const _diagnostics = bool.fromEnvironment('BAHA_DIAGNOSTICS');
  int? _firstTimedFrame, _lastTimedFrame;
  int _timedFrames = 0, _slowBuilds = 0, _slowRasters = 0;
  int _maxBuildUs = 0, _maxRasterUs = 0;
  VideoPlayerController? _video;
  bool _failed = false;
  int get cachedTextPainters => _text.length;
  int get cachedRasterBytes => _sprites.bytes;
  int get cachedRasterImages => _sprites.length;
  static const maximumTextPainters = 64;

  @override
  void initState() {
    super.initState();
    // Notification arrival time is not animation time. Use the shared engine
    // frame timestamp so all movement in a rendered frame has one time base.
    _animationClock = DanmakuAnimationClock(
      now: () => SchedulerBinding.instance.currentSystemFrameTimeStamp,
    );
    if (_diagnostics) {
      SchedulerBinding.instance.addTimingsCallback(_recordTimings);
    }
    _ticker = createTicker((_) {
      final state = widget.playback.state;
      _position.value = math.min(state.duration, _animationClock.position);
    });
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
    if (oldWidget.playback != widget.playback) {
      oldWidget.playback.removeListener(_changed);
      widget.playback.addListener(_changed);
    }
    if (oldWidget.settings != widget.settings) _clearText();
    _changed();
  }

  void _changed() {
    if (!mounted) return;
    final state = widget.playback.state;
    _animationClock.update(
      position: state.position,
      rate: state.rate,
      running: !state.paused && !state.buffering,
    );
    _position.value = math.min(state.duration, _animationClock.position);
    final animate =
        !state.paused && !state.buffering && widget.settings.enabled;
    if (animate && !_ticker.isActive) _ticker.start();
    if (!animate && _ticker.isActive) _ticker.stop();
    final failed = state.phase.name == 'error';
    if (_video != widget.playback.video || _failed != failed) {
      setState(() {
        _video = widget.playback.video;
        _failed = failed;
      });
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
    if (!mounted || !_ticker.isActive || widget.playback.state.paused) {
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
      '[BAHA_DANMAKU] ${jsonEncode({'frames': _timedFrames, 'windowSeconds': double.parse(seconds.toStringAsFixed(3)), 'fps': double.parse(((_timedFrames - 1) / seconds).toStringAsFixed(2)), 'buildOver16ms': _slowBuilds, 'rasterOver16ms': _slowRasters, 'maxBuildMs': _maxBuildUs / 1000, 'maxRasterMs': _maxRasterUs / 1000, 'textPainters': _text.length, 'rasterImages': _sprites.length, 'rasterBytes': _sprites.bytes})}',
    );
    _resetTimings();
  }

  void _resetTimings() {
    _firstTimedFrame = _lastTimedFrame = null;
    _timedFrames = _slowBuilds = _slowRasters = 0;
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
    _ticker.dispose();
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
