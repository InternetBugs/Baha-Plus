import 'dart:convert';
import 'models.dart';

const communityReadActions = {
  'comments',
  'replies',
  'notifications',
  'notification-target',
};

class CommunityException implements Exception {
  const CommunityException(this.code);
  final String code;
  bool get needsLogin => code == 'login';
  @override
  String toString() => 'CommunityException($code)';
}

String _text(dynamic value, int maximum, {bool empty = true}) {
  if (value is! String ||
      value.runes.length > maximum ||
      (!empty && value.trim().isEmpty)) {
    throw const FormatException('Invalid community text');
  }
  return value;
}

int _count(dynamic value, [int maximum = 100000000]) {
  if (value is! int || value < 0 || value > maximum) {
    throw const FormatException('Invalid community count');
  }
  return value;
}

String _id(dynamic value) {
  if (value is! String || !RegExp(r'^[0-9]{1,20}$').hasMatch(value)) {
    throw const FormatException('Invalid community ID');
  }
  return value;
}

String? _image(dynamic value) {
  if (value == null) return null;
  final uri = value is String ? Uri.tryParse(value) : null;
  if (uri == null ||
      !OfficialSite.validImage(value as String) ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443) {
    throw const FormatException('Invalid community image');
  }
  return value;
}

class OfficialComment {
  OfficialComment.fromJson(Json json)
    : id = _id(json['id']),
      name = _text(json['name'], 200, empty: false),
      userId = _text(json['userId'], 100, empty: false),
      text = _text(json['text'], 20000),
      time = _text(json['time'], 100),
      avatar = _image(json['avatar']),
      image = _image(json['image']),
      likes = _count(json['likes']),
      dislikes = _count(json['dislikes']),
      replies = _count(json['replies']),
      vote = json['vote'] as int,
      folded = json['folded'] as bool {
    if (!const [-1, 0, 1].contains(vote)) {
      throw const FormatException('Invalid comment vote');
    }
  }
  final String id, name, userId, text, time;
  final String? avatar, image;
  final int likes, dislikes, replies, vote;
  final bool folded;
}

class CommentPage {
  CommentPage.fromJson(Json json)
    : messageId = _id(json['messageId']),
      total = _count(json['total']),
      nextPage = _count(json['nextPage']),
      comments = parseComments(json['comments']);
  final String messageId;
  final int total, nextPage;
  final List<OfficialComment> comments;

  static List<OfficialComment> parseComments(dynamic value) {
    final raw = value as List;
    if (raw.length > 200) {
      throw const FormatException('Too many comments');
    }
    final items = raw
        .map((item) => OfficialComment.fromJson(item as Json))
        .toList(growable: false);
    if (items.map((item) => item.id).toSet().length != items.length) {
      throw const FormatException('Duplicate comments');
    }
    return items;
  }
}

class AnimeNotification {
  AnimeNotification.fromJson(Json json)
    : id = _text(json['id'], 500, empty: false),
      title = _text(json['title'], 500, empty: false),
      time = _text(json['time'], 100),
      videoId = _text(json['videoId'], 10, empty: false),
      cover = _image(json['cover']) {
    if (!OfficialSite.validId(videoId)) {
      throw const FormatException('Invalid notification episode');
    }
  }
  final String id, title, time, videoId;
  final String? cover;
}

class DanmakuSettings {
  const DanmakuSettings({
    this.enabled = true,
    this.opacity = .8,
    this.scale = 1,
    this.rolling = true,
    this.top = true,
    this.bottom = true,
  });

  factory DanmakuSettings.fromJson(Json json) {
    final result = DanmakuSettings(
      enabled: json['enabled'] as bool,
      opacity: (json['opacity'] as num).toDouble(),
      scale: (json['scale'] as num).toDouble(),
      rolling: json['rolling'] as bool,
      top: json['top'] as bool,
      bottom: json['bottom'] as bool,
    );
    if (!result.opacity.isFinite ||
        result.opacity < .1 ||
        result.opacity > 1 ||
        !result.scale.isFinite ||
        result.scale < .5 ||
        result.scale > 1.5) {
      throw const FormatException('Invalid danmaku settings');
    }
    return result;
  }

  final bool enabled, rolling, top, bottom;
  final double opacity, scale;
  Json toJson() => {
    'enabled': enabled,
    'opacity': opacity,
    'scale': scale,
    'rolling': rolling,
    'top': top,
    'bottom': bottom,
  };

  DanmakuSettings copyWith({
    bool? enabled,
    double? opacity,
    double? scale,
    bool? rolling,
    bool? top,
    bool? bottom,
  }) => DanmakuSettings.fromJson({
    ...toJson(),
    'enabled': ?enabled,
    'opacity': ?opacity,
    'scale': ?scale,
    'rolling': ?rolling,
    'top': ?top,
    'bottom': ?bottom,
  });

  static bool validMessage(String text) =>
      text.trim().isNotEmpty && utf8.encode(text.trim()).length <= 60;
}
