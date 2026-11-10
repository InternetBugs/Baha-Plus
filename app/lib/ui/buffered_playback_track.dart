import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../core/playback_state.dart';

/// Paints the buffer below the slider's active track and glass thumb.
class BufferedPlaybackTrack extends StatelessWidget {
  const BufferedPlaybackTrack({
    required this.state,
    required this.color,
    required this.child,
    super.key,
  });

  final PlaybackState state;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BufferPainter(
      duration: state.duration,
      ranges: state.bufferRanges,
      trackColor: color.withValues(alpha: .16),
      textDirection: Directionality.of(context),
    ),
    child: child,
  );
}

class _BufferPainter extends CustomPainter {
  _BufferPainter({
    required this.duration,
    required this.ranges,
    required this.trackColor,
    required this.textDirection,
  });

  final double duration;
  final List<PlaybackBufferRange> ranges;
  final Color trackColor;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    // GlassSlider paints its track across the full width, at the vertical center.
    final track = Rect.fromLTWH(0, (size.height - 4) / 2, size.width, 4);
    final rounded = RRect.fromRectAndRadius(track, const Radius.circular(2));
    canvas.drawRRect(rounded, Paint()..color = trackColor);
    if (duration <= 0 || !duration.isFinite) return;
    canvas.save();
    canvas.clipRRect(rounded);
    final paint = Paint()..color = const Color(0xff8e8e93);
    for (final range in ranges) {
      final start = (range.start / duration).clamp(0.0, 1.0);
      final end = (range.end / duration).clamp(0.0, 1.0);
      if (end <= start) continue;
      canvas.drawRect(
        Rect.fromLTWH(
          size.width * (textDirection == TextDirection.rtl ? 1 - end : start),
          track.top,
          size.width * (end - start),
          track.height,
        ),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BufferPainter oldDelegate) =>
      duration != oldDelegate.duration ||
      !listEquals(ranges, oldDelegate.ranges) ||
      trackColor != oldDelegate.trackColor ||
      textDirection != oldDelegate.textDirection;
}
