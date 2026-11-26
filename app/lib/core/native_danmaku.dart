import 'dart:ui' show Color;

import 'models.dart';

class NativeDanmaku {
  NativeDanmaku({
    required this.id,
    required this.text,
    required String mode,
    required this.time,
    required this.size,
    required this.color,
  }) : mode = _canonicalMode(mode) {
    _validate();
  }

  NativeDanmaku.fromJson(Json json)
    : id = json['id'] as String,
      text = json['text'] as String,
      mode = _canonicalMode(json['mode'] as String),
      time = (json['time'] as num).toDouble(),
      size = (json['size'] as num).toDouble(),
      color = parseColor(json['color']) {
    _validate();
  }

  static String _canonicalMode(String raw) => switch (raw) {
    'rolling' => 'rolling',
    'top' => 'top',
    'bottom' => 'bottom',
    _ => throw const FormatException('Invalid native danmaku'),
  };

  void _validate() {
    if (!_isAsciiDigits(id) ||
        text.isEmpty ||
        text.length > 500 ||
        !time.isFinite ||
        time < 0 ||
        time > 172800 ||
        !size.isFinite ||
        size < 12 ||
        size > 40) {
      throw const FormatException('Invalid native danmaku');
    }
  }

  static bool _isAsciiDigits(String value) {
    final length = value.length;
    if (length == 0 || length > 20) return false;
    for (var i = 0; i < length; i++) {
      if ((value.codeUnitAt(i) ^ 0x30) > 9) return false;
    }
    return true;
  }

  final String id, text, mode;
  final double time, size;
  final Color color;

  bool get isRolling => identical(mode, 'rolling') || mode == 'rolling';
  double get duration => isRolling ? 10.0 : 5.0;

  static Color parseColor(dynamic value) {
    if (value is! String || value.length != 7 || value.codeUnitAt(0) != 0x23) {
      throw const FormatException('Invalid native danmaku color');
    }
    if (value == '#FFFFFF' || value == '#ffffff') {
      return const Color(0xFFFFFFFF);
    }
    var rgb = 0;
    for (var i = 1; i < 7; i++) {
      final c = value.codeUnitAt(i);
      final int digit;
      if (c >= 0x30 && c <= 0x39) {
        digit = c - 0x30;
      } else if (c >= 0x41 && c <= 0x46) {
        digit = c - 0x41 + 10;
      } else if (c >= 0x61 && c <= 0x66) {
        digit = c - 0x61 + 10;
      } else {
        throw const FormatException('Invalid native danmaku color');
      }
      rgb = (rgb << 4) | digit;
    }
    return Color(0xFF000000 | rgb);
  }
}
