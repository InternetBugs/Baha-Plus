import 'dart:convert';
import 'dart:math' as math;
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

final _communityId = RegExp(r'^[0-9]{1,20}$');

String _id(dynamic value) {
  if (value is! String || !_communityId.hasMatch(value)) {
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
  const OfficialComment({
    required this.id,
    required this.name,
    required this.userId,
    required this.text,
    required this.time,
    this.avatar,
    this.image,
    required this.likes,
    required this.dislikes,
    required this.replies,
    required this.vote,
    required this.folded,
  });

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

  Json toJson() => {
    'id': id,
    'name': name,
    'userId': userId,
    'text': text,
    'time': time,
    'avatar': avatar,
    'image': image,
    'likes': likes,
    'dislikes': dislikes,
    'replies': replies,
    'vote': vote,
    'folded': folded,
  };

  OfficialComment copyWith({
    int? likes,
    int? dislikes,
    int? replies,
    int? vote,
    bool? folded,
  }) => OfficialComment(
    id: id,
    name: name,
    userId: userId,
    text: text,
    time: time,
    avatar: avatar,
    image: image,
    likes: likes ?? this.likes,
    dislikes: dislikes ?? this.dislikes,
    replies: replies ?? this.replies,
    vote: vote ?? this.vote,
    folded: folded ?? this.folded,
  );

  OfficialComment withVote(int type) {
    final desired = switch (type) {
      1 => 1,
      2 => -1,
      _ => throw const CommunityException('input'),
    };
    final nextVote = vote == desired ? 0 : desired;
    return copyWith(
      likes: math.max(0, likes - (vote == 1 ? 1 : 0) + (nextVote == 1 ? 1 : 0)),
      dislikes: math.max(
        0,
        dislikes - (vote == -1 ? 1 : 0) + (nextVote == -1 ? 1 : 0),
      ),
      vote: nextVote,
    );
  }
}

class CommentPage {
  static final _postableId = RegExp(r'^[1-9][0-9]{0,19}$');
  const CommentPage({
    required this.messageId,
    required this.total,
    required this.nextPage,
    required this.comments,
  });

  CommentPage.fromJson(Json json)
    : messageId = _id(json['messageId']),
      total = _count(json['total']),
      nextPage = _count(json['nextPage']),
      comments = parseComments(json['comments']);
  final String messageId;
  final int total, nextPage;
  final List<OfficialComment> comments;
  bool get canPost => _postableId.hasMatch(messageId);

  CommentPage copyWith({
    String? messageId,
    int? total,
    int? nextPage,
    List<OfficialComment>? comments,
  }) => CommentPage(
    messageId: messageId ?? this.messageId,
    total: total ?? this.total,
    nextPage: nextPage ?? this.nextPage,
    comments: comments ?? this.comments,
  );

  static List<OfficialComment> parseComments(
    dynamic value, {
    int maxItems = 200,
  }) {
    final raw = value as List;
    if (raw.length > maxItems) {
      throw const FormatException('Too many comments');
    }
    final ids = <String>{};
    return raw
        .map((item) {
          final comment = OfficialComment.fromJson(item as Json);
          if (!ids.add(comment.id)) {
            throw const FormatException('Duplicate comments');
          }
          return comment;
        })
        .toList(growable: false);
  }
}

class CommentDraft {
  const CommentDraft({this.text = '', this.replyThread, this.replyTarget});

  final String text;
  final OfficialComment? replyThread;
  final OfficialComment? replyTarget;
  bool get isEmpty =>
      text.isEmpty && replyThread == null && replyTarget == null;
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

  Json toJson() => {
    'id': id,
    'title': title,
    'time': time,
    'videoId': videoId,
    'cover': cover,
  };
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
    return result._validated();
  }

  DanmakuSettings _validated() {
    if (!opacity.isFinite ||
        opacity < .1 ||
        opacity > 1 ||
        !scale.isFinite ||
        scale < .5 ||
        scale > 1.5) {
      throw const FormatException('Invalid danmaku settings');
    }
    return this;
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
  }) => DanmakuSettings(
    enabled: enabled ?? this.enabled,
    opacity: opacity ?? this.opacity,
    scale: scale ?? this.scale,
    rolling: rolling ?? this.rolling,
    top: top ?? this.top,
    bottom: bottom ?? this.bottom,
  )._validated();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DanmakuSettings &&
          enabled == other.enabled &&
          opacity == other.opacity &&
          scale == other.scale &&
          rolling == other.rolling &&
          top == other.top &&
          bottom == other.bottom;

  @override
  int get hashCode =>
      Object.hash(enabled, opacity, scale, rolling, top, bottom);

  static bool validMessage(String text) =>
      text.trim().isNotEmpty && utf8.encode(text.trim()).length <= 60;
}
