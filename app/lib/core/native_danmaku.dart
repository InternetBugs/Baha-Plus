import 'dart:ui' show Color;

import 'models.dart';

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
        size > 40) {
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
