import 'dart:convert';

typedef Json = Map<String, dynamic>;

class OfficialSite {
  static final home = Uri.parse('https://ani.gamer.com.tw/');
  static final _id = RegExp(r'^[0-9]{1,10}$');

  static bool validId(String value) => _id.hasMatch(value);
  static bool allowedNavigation(Uri url) =>
      url.scheme == 'https' &&
      (url.host == 'gamer.com.tw' || url.host.endsWith('.gamer.com.tw'));
  static bool trustedOrigin(Uri url) =>
      url.scheme == 'https' &&
      url.host == 'ani.gamer.com.tw' &&
      url.port == 443;
  static bool desktopPlayer(Uri url) =>
      trustedOrigin(url) &&
      const ['/animeRef.php', '/animeVideo.php'].contains(url.path);
  static bool validImage(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.endsWith('.bahamut.com.tw');
  }

  static Uri series(String id) {
    if (!validId(id)) throw const FormatException('Invalid series ID');
    return home.resolve('animeRef.php').replace(queryParameters: {'sn': id});
  }

  static Uri video(String id) {
    if (!validId(id)) throw const FormatException('Invalid video ID');
    return home.resolve('animeVideo.php').replace(queryParameters: {'sn': id});
  }

  static Uri search(String query) => home
      .resolve('search.php')
      .replace(
        queryParameters: {
          'keyword': String.fromCharCodes(query.runes.take(100)),
        },
      );
}

class Anime {
  const Anime({
    required this.id,
    required this.title,
    required this.cover,
    this.poster,
    this.latestVideoId,
    this.episodeLabel,
    this.updateDay,
    this.updateTime,
    this.updateDate,
    this.views,
    this.year,
    this.sections = const [],
  });

  factory Anime.fromJson(Json json) {
    final value = Anime(
      id: json['id'] as String,
      title: json['title'] as String,
      cover: json['cover'] as String,
      poster: json['poster'] as String?,
      latestVideoId: json['latestVideoId'] as String?,
      episodeLabel: json['episodeLabel'] as String?,
      updateDay: json['updateDay'] as int?,
      updateTime: json['updateTime'] as String?,
      updateDate: json['updateDate'] as String?,
      views: json['views'] as String?,
      year: json['year'] as String?,
      sections: (json['sections'] as List).cast<String>(),
    );
    if (!value.isValid) throw const FormatException('Invalid anime');
    return value;
  }

  final String id, title, cover;
  final String? poster,
      latestVideoId,
      episodeLabel,
      updateTime,
      updateDate,
      views,
      year;
  final int? updateDay;
  final List<String> sections;
  String get artwork => poster ?? cover;

  bool get isValid =>
      OfficialSite.validId(id) &&
      title.isNotEmpty &&
      title.runes.length < 500 &&
      OfficialSite.validImage(cover) &&
      (poster == null || OfficialSite.validImage(poster!)) &&
      (latestVideoId == null || OfficialSite.validId(latestVideoId!)) &&
      (updateDay == null || (updateDay! >= 0 && updateDay! <= 6)) &&
      (updateDate == null || Catalog.validDate(updateDate!)) &&
      sections.every(const ['season', 'hot', 'new'].contains);

  Json toJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    if (poster != null) 'poster': poster,
    if (latestVideoId != null) 'latestVideoId': latestVideoId,
    if (episodeLabel != null) 'episodeLabel': episodeLabel,
    if (updateDay != null) 'updateDay': updateDay,
    if (updateTime != null) 'updateTime': updateTime,
    if (updateDate != null) 'updateDate': updateDate,
    if (views != null) 'views': views,
    if (year != null) 'year': year,
    'sections': sections,
  };
}

class Catalog {
  const Catalog({this.items = const [], this.fetchedAt = ''});
  factory Catalog.fromJson(Json json) {
    final result = Catalog(
      items: (json['items'] as List)
          .map((value) => Anime.fromJson(value as Json))
          .toList(growable: false),
      fetchedAt: json['fetchedAt'] as String,
    );
    if (!result.isValid) throw const FormatException('Invalid catalog');
    return result;
  }
  final List<Anime> items;
  final String fetchedAt;
  bool get isValid =>
      items.isNotEmpty &&
      items.length <= 5000 &&
      items.every((item) => item.isValid) &&
      items.map((item) => item.id).toSet().length == items.length &&
      validTimestamp(fetchedAt);
  Json toJson() => {
    'items': items.map((item) => item.toJson()).toList(),
    'fetchedAt': fetchedAt,
  };
  String encode() => jsonEncode(toJson());

  static bool validTimestamp(String value) =>
      RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
      ).hasMatch(value) &&
      DateTime.tryParse(value) != null;

  static bool validDate(String value) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) &&
      (DateTime.tryParse(value)?.toIso8601String().startsWith('${value}T') ??
          false);
}

class Episode {
  const Episode({required this.id, required this.label});
  factory Episode.fromJson(Json json) {
    final value = Episode(
      id: json['id'] as String,
      label: json['label'] as String,
    );
    if (!OfficialSite.validId(value.id) || value.label.length > 100) {
      throw const FormatException('Invalid episode');
    }
    return value;
  }
  final String id, label;
}

class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.displayName,
    this.avatar,
  });

  factory AccountProfile.fromJson(Json json) {
    final profile = AccountProfile(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      avatar: json['avatar'] as String?,
    );
    final avatarUri = profile.avatar == null
        ? null
        : Uri.tryParse(profile.avatar!);
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(profile.id) ||
        profile.displayName.trim().isEmpty ||
        profile.displayName.runes.length > 100 ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(profile.displayName) ||
        (profile.avatar != null &&
            (avatarUri == null ||
                !OfficialSite.validImage(profile.avatar!) ||
                avatarUri.userInfo.isNotEmpty ||
                avatarUri.port != 443))) {
      throw const FormatException('Invalid official account profile');
    }
    return profile;
  }

  final String id, displayName;
  final String? avatar;
}

class Metadata {
  const Metadata({required this.label, required this.value});
  factory Metadata.fromJson(Json json) {
    final item = Metadata(
      label: json['label'] as String,
      value: json['value'] as String,
    );
    if (item.label.length > 200 || item.value.length > 4000) {
      throw const FormatException('Invalid metadata');
    }
    return item;
  }
  final String label, value;
}

class RatingSummary {
  RatingSummary.fromJson(Json json)
    : value = (json['value'] as num).toDouble(),
      count = json['count'] as int,
      distribution = (json['distribution'] as List).cast<int>() {
    if (!value.isFinite ||
        value < 0 ||
        value > 5 ||
        count < 0 ||
        count > 100000000 ||
        distribution.length != 5 ||
        distribution.any((item) => item < 0 || item > count) ||
        distribution.fold<int>(0, (sum, item) => sum + item) > count) {
      throw const FormatException('Invalid rating summary');
    }
  }

  final double value;
  final int count;
  final List<int> distribution;

  Json toJson() => {
    'value': value,
    'count': count,
    'distribution': distribution,
  };
}

class AnimeDetail {
  AnimeDetail.fromJson(Json json)
    : title = json['title'] as String,
      description = json['description'] as String,
      poster = json['poster'] as String?,
      rating = json['rating'] == null
          ? null
          : RatingSummary.fromJson(json['rating'] as Json),
      episodes = (json['episodes'] as List)
          .map((item) => Episode.fromJson(item as Json))
          .toList(growable: false),
      metadata = (json['metadata'] as List)
          .map((item) => Metadata.fromJson(item as Json))
          .toList(growable: false) {
    if (title.isEmpty ||
        title.length >= 500 ||
        description.length > 200000 ||
        (poster != null && !OfficialSite.validImage(poster!)) ||
        episodes.length > 5000 ||
        episodes.map((item) => item.id).toSet().length != episodes.length ||
        metadata.length > 100) {
      throw const FormatException('Invalid anime detail');
    }
  }
  final String title, description;
  final String? poster;
  final RatingSummary? rating;
  final List<Episode> episodes;
  final List<Metadata> metadata;
}

class WatchEntry {
  WatchEntry.fromJson(Json json)
    : anime = Anime.fromJson(json['anime'] as Json),
      videoId = json['videoId'] as String,
      episodeLabel = json['episodeLabel'] as String,
      progress = (json['progress'] as num?)?.toDouble(),
      progressLabel = json['progressLabel'] as String?,
      watchedAt = json['watchedAt'] == null
          ? null
          : DateTime.parse(json['watchedAt'] as String),
      nextVideoId = json['nextVideoId'] as String? {
    if (!OfficialSite.validId(videoId) ||
        episodeLabel.length > 200 ||
        (progressLabel?.length ?? 0) > 2000 ||
        (watchedAt != null &&
            !Catalog.validTimestamp(json['watchedAt'] as String)) ||
        (nextVideoId != null &&
            (!RegExp(r'^[1-9]\d{0,9}$').hasMatch(nextVideoId!) ||
                nextVideoId == videoId)) ||
        (progress != null &&
            (!progress!.isFinite || progress! < 0 || progress! > 1))) {
      throw const FormatException('Invalid cloud history');
    }
  }
  final Anime anime;
  final String videoId, episodeLabel;
  final double? progress;
  final String? progressLabel;
  final DateTime? watchedAt;
  final String? nextVideoId;
}
