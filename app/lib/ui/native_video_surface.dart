import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';
import '../core/community.dart';
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
  DateTime _sampledAt = DateTime.now();
  double _sampledPosition = 0;
  VideoPlayerController? _video;
  bool _failed = false;
  int get cachedTextPainters => _text.length;
  static const maximumTextPainters = 64;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      final state = widget.playback.state;
      _position.value = math.min(
        state.duration,
        _sampledPosition +
            DateTime.now().difference(_sampledAt).inMicroseconds /
                1e6 *
                state.rate,
      );
    });
    widget.playback.addListener(_changed);
    _changed();
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
    _sampledPosition = state.position;
    _sampledAt = DateTime.now();
    _position.value = state.position;
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
    for (final painter in _text.values) {
      painter.dispose();
    }
    _text.clear();
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
    _ticker.dispose();
    _position.dispose();
    _clearText();
    super.dispose();
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.position,
    required this.items,
    required this.settings,
    required this.text,
  }) : super(repaint: position);
  final ValueNotifier<double> position;
  final List<NativeDanmaku> items;
  final DanmakuSettings settings;
  final Map<String, TextPainter> text;

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
      final lanes = math.max(1, (size.height * .65 / lineHeight).floor());
      final rolling = List<double>.filled(lanes, -1);
      final top = List<double>.filled(lanes, -1);
      final bottom = List<double>.filled(lanes, -1);
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
        final available = switch (item.mode) {
          'top' => top,
          'bottom' => bottom,
          _ => rolling,
        };
        final lane = available.indexWhere((until) => until <= item.time);
        if (lane < 0) continue;
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
        painter.paint(canvas, Offset(x, y));
        // A lane is reused only after the previous message has left it.
        available[lane] = item.time + duration;
      }
      canvas.restore();
    }
    for (final id in text.keys.where((id) => !retained.contains(id)).toList()) {
      text.remove(id)!.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.items != items || oldDelegate.settings != settings;
}
