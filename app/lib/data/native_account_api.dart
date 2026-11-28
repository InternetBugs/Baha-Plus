import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:html/dom.dart';

import '../core/community.dart';
import '../core/models.dart';
import 'device_storage.dart';
import 'official_account_profile.dart';
import 'official_http_client.dart';

/// Official account, collection and community endpoints, executed in Dart.
/// The collection/profile endpoints return HTML; it is parsed as inert data.
/// The transport persists official login-cookie rotations in the device store.
class NativeAccountApi {
  NativeAccountApi({OfficialHttpClient? transport})
    : transport = transport ?? OfficialHttpClient();

  final OfficialHttpClient transport;

  /// Notify the official service using the existing session, then remove the
  /// device session even when the service is unreachable.
  Future<void> logout() async {
    try {
      await transport.session((session) async {
        final page = await parseOfficialHtml(
          await session.get(OfficialSite.logout),
        );
        // GET only renders the official confirmation page. The button posts
        // this per-session token; parse it as data without executing scripts.
        String? token;
        for (final form in page.querySelectorAll('form')) {
          if (OfficialSite.logout.resolve(form.attributes['action'] ?? '') ==
                  OfficialSite.logout &&
              form.attributes['method']?.toUpperCase() == 'POST') {
            token = form
                .querySelector('input[name="token"]')
                ?.attributes['value'];
            if (token != null) break;
          }
        }
        if (token == null) {
          for (final script in page.querySelectorAll('script:not([src])')) {
            if (!_logoutFunction.hasMatch(script.text)) continue;
            token = _logoutToken.firstMatch(script.text)?[1];
            if (token != null) break;
          }
        }
        if (token == null) {
          if (session.cookies.header(OfficialSite.logout).isEmpty) return;
          throw const CommunityException('format');
        }
        if (!_validLogoutToken.hasMatch(token)) {
          throw const CommunityException('format');
        }
        await session.post(OfficialSite.logout, {'token': token});
      });
    } finally {
      await transport.clearCookies();
    }
  }

  static final _logoutFunction = RegExp(r'function\s+logout\s*\(\s*\)\s*\{');
  static final _logoutToken = RegExp(
    r'''\.name\s*=\s*['"]token['"]\s*;[\s\S]{0,256}?\.value\s*=\s*['"]([A-Za-z0-9_-]{16,256})['"]''',
  );
  static final _validLogoutToken = RegExp(r'^[A-Za-z0-9_-]{16,256}$');

  static final _id = RegExp(r'^[1-9][0-9]{0,19}$');
  static final _videoId = RegExp(r'^[1-9][0-9]{0,9}$');
  static final _gather = RegExp(r'toggleGather\(\s*(\d+)\s*,\s*(\d+)\s*,');
  static final _invalidToken = RegExp(r'[<>\r\n]');
  static final _messageId = RegExp(r'^[0-9]{1,20}$');
  static final _spaces = RegExp(r'\s+');
  static final _relativeTime = RegExp(r'(?:\d+\s*(?:秒|分|分鐘|小時|天|日)前|昨天|今天)');
  static final _episodeSuffix = RegExp(r'\s*\[[^\]]+\]\s*$');
  static final _integerText = RegExp(r'^-?[0-9]+$');
  static Uri _web(String path, [Map<String, String>? query]) =>
      Uri.https('ani.gamer.com.tw', path, query);
  static Uri _wall(String path, [Map<String, String>? query]) =>
      Uri.https('wall.gamer.com.tw', '/app/$path', query);

  static String? _image(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final uri = _web('/').resolve(raw);
    return OfficialSite.validImage(uri.toString()) &&
            uri.userInfo.isEmpty &&
            uri.port == 443
        ? uri.toString()
        : null;
  }

  Future<AccountProfile> _requireProfile(
    OfficialHttpSession session,
    String? expectedOwner,
  ) async {
    final uri = _web('/mygather.php');
    if (session.cookies.header(uri).isEmpty) {
      throw const CommunityException('login');
    }
    final profile = parseOfficialAccountProfile(
      await parseOfficialHtml(await session.get(uri)),
    );
    if (profile == null) throw const CommunityException('login');
    if (expectedOwner != null &&
        profile.id.toLowerCase() != expectedOwner.toLowerCase()) {
      throw const CommunityException('stale');
    }
    return profile;
  }

  /// Refreshes display data without fetching collections or watch history.
  Future<Json?> fetchProfile({void Function()? checkCurrent}) async {
    final profile = await _fetchProfileModel(checkCurrent: checkCurrent);
    return profile == null ? null : _projectProfile(profile);
  }

  Future<AccountProfile?> fetchProfileModel({
    void Function()? checkCurrent,
  }) async {
    final raw = await fetchProfile(checkCurrent: checkCurrent);
    return raw == null ? null : _profileFrom(raw);
  }

  static Json _projectProfile(AccountProfile profile) =>
      _ModelProjection(profile, (value) => value.toJson());

  static AccountProfile _profileFrom(Json raw) =>
      _originalModel<AccountProfile>(raw) ?? AccountProfile.fromJson(raw);

  Future<AccountProfile?> _fetchProfileModel({void Function()? checkCurrent}) =>
      transport.session((session) async {
        if (session.cookies.header(_web('/mygather.php')).isEmpty) return null;
        AccountProfile? identity;
        try {
          identity = parseOfficialAccountProfile(
            await parseOfficialHtml(await session.get(_web('/mygather.php'))),
          );
        } on CommunityException catch (error) {
          if (error.code != 'login') rethrow;
          await session.revalidate();
          return null;
        }
        if (identity == null) {
          await session.revalidate();
          return null;
        }
        final owner = identity.id;
        final page = await parseOfficialHtml(
          await session.get(
            Uri.https('home.gamer.com.tw', '/profile/index.php', {
              'owner': owner,
            }),
          ),
        );
        final profile = parseOfficialPublicAccountProfile(page, owner: owner);
        await session.revalidate();
        return profile;
      }, checkCurrent: checkCurrent);

  Future<Json?> fetchAccount({
    void Function()? checkCurrent,
    String? expectedOwner,
    void Function(Json profile)? onAuthenticated,
  }) async {
    final snapshot = await _fetchAccountSnapshot(
      checkCurrent: checkCurrent,
      expectedOwner: expectedOwner,
      onAuthenticated: onAuthenticated == null
          ? null
          : (profile) => onAuthenticated(_projectProfile(profile)),
    );
    return snapshot == null
        ? null
        : _ModelProjection(snapshot, (value) => value.toJson());
  }

  Future<AccountSnapshot?> fetchAccountSnapshot({
    void Function()? checkCurrent,
    String? expectedOwner,
    void Function(AccountProfile profile)? onAuthenticated,
  }) async {
    final raw = await fetchAccount(
      checkCurrent: checkCurrent,
      expectedOwner: expectedOwner,
      onAuthenticated: onAuthenticated == null
          ? null
          : (profile) => onAuthenticated(_profileFrom(profile)),
    );
    return raw == null
        ? null
        : _originalModel<AccountSnapshot>(raw) ?? AccountSnapshot.fromJson(raw);
  }

  Future<AccountSnapshot?> _fetchAccountSnapshot({
    void Function()? checkCurrent,
    String? expectedOwner,
    void Function(AccountProfile profile)? onAuthenticated,
  }) => transport.session((session) async {
    if (session.cookies.header(_web('/mygather.php')).isEmpty) {
      if (expectedOwner != null) throw const CommunityException('login');
      return null;
    }
    Document page;
    try {
      page = await parseOfficialHtml(await session.get(_web('/mygather.php')));
    } on CommunityException catch (error) {
      if (error.code == 'login' && expectedOwner == null) {
        await session.revalidate();
        return null;
      }
      rethrow;
    }
    final profile = parseOfficialAccountProfile(page);
    if (profile == null) {
      if (expectedOwner != null) throw const CommunityException('login');
      await session.revalidate();
      return null;
    }
    final owner = profile.id.toLowerCase();
    if (expectedOwner != null && expectedOwner.toLowerCase() != owner) {
      throw const CommunityException('stale');
    }
    await session.revalidate();
    onAuthenticated?.call(profile);
    final (favorites, history) = await (
      _favorites(session, page, owner),
      _history(session),
    ).waitWithOriginalError();
    await session.revalidate();
    return AccountSnapshot(
      profile: profile,
      favorites: favorites,
      history: history,
    );
  }, checkCurrent: checkCurrent);

  Future<List<Anime>> _favorites(
    OfficialHttpSession session,
    Document first,
    String owner,
  ) async {
    final favorites = <String, Anime>{};
    final initial = _web('/mygather.php');
    final visited = {initial};
    final queue = <Uri>[];
    void collect(Uri uri, Document document, {bool first = false}) {
      if (!first &&
          parseOfficialAccountProfile(document)?.id.toLowerCase() != owner) {
        throw const CommunityException('stale');
      }
      if (document.querySelector('.theme-title')?.text.contains('我的動畫') !=
          true) {
        throw const CommunityException('format');
      }
      for (final card in document.querySelectorAll(
        'a.theme-list-main, a.anime-card-block',
      )) {
        final href = _web('/').resolve(card.attributes['href'] ?? '');
        final onclick =
            card
                .querySelector('[onclick*="toggleGather"]')
                ?.attributes['onclick'] ??
            '';
        final id =
            _gather.firstMatch(onclick)?[2] ??
            (href.path == '/animeRef.php' ? href.queryParameters['sn'] : null);
        final title = card
            .querySelector('.theme-name, .anime-name')
            ?.text
            .trim();
        final img = card.querySelector('img.theme-img, .anime-blocker img');
        final cover = _image(
          img?.attributes['data-src'] ?? img?.attributes['src'],
        );
        if (id == null ||
            !_videoId.hasMatch(id) ||
            title == null ||
            title.isEmpty ||
            cover == null) {
          throw const CommunityException('format');
        }
        final item = <String, dynamic>{
          'id': id,
          'title': title,
          'cover': cover,
          'poster': cover,
          if (href.host == 'ani.gamer.com.tw' &&
              href.path == '/animeVideo.php' &&
              _videoId.hasMatch(href.queryParameters['sn'] ?? ''))
            'latestVideoId': href.queryParameters['sn'],
          'sections': <String>[],
        };
        favorites[id] = Anime.fromJson(item);
        if (favorites.length > 10000) throw const CommunityException('format');
      }
      for (final link in document.querySelectorAll('.page_number a[href]')) {
        final next = uri.resolve(link.attributes['href']!);
        if (next.origin == uri.origin &&
            next.path == '/mygather.php' &&
            next.fragment.isEmpty &&
            visited.add(next)) {
          if (visited.length > 50) throw const CommunityException('format');
          queue.add(next);
        }
      }
    }

    collect(initial, first, first: true);
    for (var offset = 0; offset < queue.length;) {
      final batch = queue.skip(offset).take(2).toList();
      offset += batch.length;
      final pages = await Future.wait([
        for (final uri in batch) session.get(uri).then(parseOfficialHtml),
      ]);
      for (final (index, uri) in batch.indexed) {
        collect(uri, pages[index]);
      }
    }
    return favorites.values.toList();
  }

  Future<List<WatchEntry>> _history(OfficialHttpSession session) async {
    final records = <String, WatchEntry>{};
    var totalPages = 1;
    for (var page = 1; page <= totalPages; page++) {
      final body = await session.json(
        Uri.https('api.gamer.com.tw', '/anime/v3/history.php', {
          'page': '$page',
        }),
      );
      final data = body['data'] as Json;
      final rows = data['history'] as List;
      final pages = data['totalPage'];
      if (pages is! int || pages < 0 || pages > 50 || rows.length > 1000) {
        throw const CommunityException('format');
      }
      totalPages = pages;
      for (final raw in rows) {
        final row = raw as Json;
        if (row['isTakenDown'] == 1 || row['isTakenDown'] == true) continue;
        final id = '${row['animeSn']}';
        if (records.containsKey(id)) continue;
        final point = (row['breakPoint'] as Json?)?['breakPoint'] as num?;
        final duration = row['duration'] as num;
        if ((point != null && (!point.isFinite || point < -1)) ||
            !duration.isFinite ||
            duration < 0) {
          throw const CommunityException('format');
        }
        final seconds = point?.floor() ?? 0;
        final watched = DateTime.tryParse(row['watchTime'] as String? ?? '');
        final next = '${row['nextVideoSn']}';
        final item = <String, dynamic>{
          'anime': {
            'id': id,
            'title': row['title'],
            'cover': row['cover'],
            'poster': row['cover'],
            'sections': <String>[],
          },
          'videoId': '${row['videoSn']}',
          'episodeLabel': row['episode'],
          if (point != null)
            'progress': point == -1
                ? 1.0
                : duration > 0
                ? (point / (duration * 60)).clamp(0.0, 1.0)
                : null,
          if (point == -1)
            'progressLabel': '觀看結束'
          else if (seconds > 0)
            'progressLabel':
                '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
          if (watched != null) 'watchedAt': watched.toUtc().toIso8601String(),
          if (_videoId.hasMatch(next) && next != '${row['videoSn']}')
            'nextVideoId': next,
        };
        records[id] = WatchEntry.fromJson(item);
        if (records.length > 1000) throw const CommunityException('format');
      }
    }
    return records.values.toList();
  }

  Future<void> setFavorite(
    Anime anime,
    bool desired, {
    required String? owner,
    required void Function() checkCurrent,
  }) => transport.session((session) async {
    if (session.cookies.header(_web('/mygather.php')).isEmpty) {
      throw const CommunityException('login');
    }
    final (_, selected, tokenResponse) = await (
      _requireProfile(session, owner),
      _favoriteButton(session, anime),
      session
          .get(_web('/ajax/getCSRFToken.php'))
          .then<Object>(
            (value) => value,
            onError: (Object error, StackTrace stack) =>
                AsyncError(error, stack),
          ),
    ).waitWithOriginalError();
    final arguments = _gather.firstMatch(selected.attributes['onclick']!)!;
    var confirmed = desired;
    if (_favoriteSelected(selected) != desired) {
      if (tokenResponse is AsyncError) {
        Error.throwWithStackTrace(
          tokenResponse.error,
          tokenResponse.stackTrace,
        );
      }
      final token = (tokenResponse as String).trim();
      if (token.isEmpty ||
          token.length > 500 ||
          token.contains(_invalidToken)) {
        throw const CommunityException('unavailable');
      }
      final response = await session.post(
        _web(desired ? '/ajax/want2play.php' : '/ajax/delgather.php'),
        {'s': arguments[1]!, 'animeSn': anime.id, 'token': token},
      );
      if (desired) {
        final xml = await parseOfficialHtml(response);
        if (xml.querySelector('errmsg') != null ||
            xml.querySelector('okmsg') == null) {
          throw const CommunityException('rejected');
        }
      } else {
        // The official handler rejects positive error codes, not every value
        // other than integer zero. An absent/unknown acknowledgement still
        // needs the authenticated state read below before confirming success.
        dynamic error;
        try {
          final result = jsonDecode(response);
          if (result is Json) error = result['error'];
        } on FormatException {
          // Empty or changed response formats require a server-state check.
        }
        if (error != null && error != false) {
          final code = error is num
              ? error
              : error is String
              ? num.tryParse(error)
              : null;
          if (code == null || !code.isFinite || code > 0) {
            throw const CommunityException('rejected');
          }
        }
      }
      confirmed = _favoriteSelected(await _favoriteButton(session, anime));
    }
    await _requireProfile(session, owner);
    await session.revalidate();
    if (confirmed != desired) throw const CommunityException('rejected');
  }, checkCurrent: checkCurrent);

  Future<Element> _favoriteButton(
    OfficialHttpSession session,
    Anime anime,
  ) async {
    final doc = await parseOfficialHtml(
      await session.get(_web('/search.php', {'keyword': anime.title})),
    );
    for (final button in doc.querySelectorAll('[onclick*="toggleGather"]')) {
      final match = _gather.firstMatch(button.attributes['onclick'] ?? '');
      if (match?[2] == anime.id) return button;
    }
    throw const CommunityException('unavailable');
  }

  bool _favoriteSelected(Element button) {
    final action = button.attributes['onclick']!;
    final selectedClass = action.contains('btn-is-active')
        ? 'btn-is-active'
        : 'ordered';
    return button.classes.contains(selectedClass);
  }

  Future<Json> community(
    String action,
    Json args, {
    required void Function() checkCurrent,
  }) async {
    final models = await _fetchCommunityModels(
      action,
      args,
      checkCurrent: checkCurrent,
    );
    return _ModelProjection(
      models,
      (result) => {
        for (final entry in result.entries)
          entry.key: switch (entry.value) {
            final List<OfficialComment> comments => [
              for (final comment in comments) comment.toJson(),
            ],
            final List<AnimeNotification> items => [
              for (final item in items) item.toJson(),
            ],
            final Anime anime => anime.toJson(),
            final value => value,
          },
      },
    );
  }

  Future<Json> communityModels(
    String action,
    Json args, {
    required void Function() checkCurrent,
  }) async {
    final result = await community(action, args, checkCurrent: checkCurrent);
    return _originalModel<Json>(result) ?? result;
  }

  Future<Json> _fetchCommunityModels(
    String action,
    Json args, {
    required void Function() checkCurrent,
  }) => transport.session((session) async {
    final owner = args['owner'] as String?;
    Json result;
    switch (action) {
      case 'comments':
        if (!_videoId.hasMatch('${args['videoId']}') ||
            !const [0, 1].contains(args['order']) ||
            args['page'] is! int ||
            (args['page'] as int) < 0 ||
            (args['page'] as int) > 100000000) {
          throw const CommunityException('input');
        }
        final body = await session.json(
          _wall('v2/comment_detail.php', {
            'service': '4',
            'serviceId': '${args['videoId']}',
            'order': '${args['order']}',
            if (args['page'] != 0) 'nextPage': '${args['page']}',
          }),
        );
        final messageId = '${body['messageId']}';
        if (!_messageId.hasMatch(messageId)) {
          throw const CommunityException('format');
        }
        result = {
          'ok': true,
          'messageId': messageId,
          'total': _integer(body['commentCount']),
          'nextPage': _integer(body['nextPage']),
          'comments': _comments(body['comments']).reversed.toList(),
        };
      case 'replies':
        if (!_id.hasMatch('${args['commentId']}')) {
          throw const CommunityException('input');
        }
        final body = await session.json(
          _wall('v1/reply_detail.php', {'commentId': '${args['commentId']}'}),
        );
        result = {
          'ok': true,
          'comments': _comments(body['comments'], maxItems: 2000),
        };
      case 'notifications':
        if (session.cookies.header(_web('/mygather.php')).isEmpty) {
          throw const CommunityException('login');
        }
        final (profile, documents) = await (
          _requireProfile(session, owner),
          Future.wait([
            for (final type in ['light_0', 'light_1'])
              session
                  .get(
                    Uri.https('api.gamer.com.tw', '/ajax/common/topBar.php', {
                      'type': type,
                    }),
                  )
                  .then(parseOfficialHtml),
          ]),
        ).waitWithOriginalError();
        final items = <String, AnimeNotification>{};
        for (final document in documents) {
          for (final anchor in document.querySelectorAll('a[href]')) {
            final href = Uri.tryParse(anchor.attributes['href']!);
            if (href == null) continue;
            final uri = _web('/').resolveUri(href);
            // Official rows also contain javascript:NOTIFY_follow actions.
            // Uri.origin throws for those schemes, failing the entire feed.
            if (uri.scheme != 'https' ||
                uri.origin != _web('/').origin ||
                uri.userInfo.isNotEmpty ||
                uri.path != '/animeVideo.php') {
              continue;
            }
            final videoIds = uri.queryParametersAll['sn'];
            if (videoIds == null ||
                videoIds.length != 1 ||
                !_videoId.hasMatch(videoIds.single)) {
              continue;
            }
            final videoId = videoIds.single;
            Element? row = anchor.parent;
            while (row != null && row.localName != 'li') {
              row = row.parent;
            }
            row ??= anchor.parent;
            final titleNode = anchor.clone(true);
            for (final node in titleNode.querySelectorAll(
              'img, small, .time, .date',
            )) {
              node.remove();
            }
            var title = titleNode.text.replaceAll(_spaces, ' ').trim();
            if (title.isEmpty) {
              title = (anchor.attributes['title'] ?? '')
                  .replaceAll(_spaces, ' ')
                  .trim();
            }
            if (title.isEmpty || title.length > 500) continue;
            final image = row?.querySelector('img');
            final item = <String, dynamic>{
              'id': 'episode:$videoId',
              'title': title,
              'videoId': videoId,
              'time':
                  row?.querySelector('.time, .date, small')?.text.trim() ??
                  _relativeTime.firstMatch(row?.text ?? '')?[0] ??
                  '',
              'cover': _image(
                image?.attributes['data-src'] ?? image?.attributes['src'],
              ),
            };
            final notification = AnimeNotification.fromJson(item);
            if (items.length < 200 || items.containsKey(notification.id)) {
              items[notification.id] = notification;
            }
          }
        }
        result = {
          'ok': true,
          'owner': profile.id.toLowerCase(),
          'items': items.values.toList(),
        };
      case 'notification-target':
        if (!_videoId.hasMatch('${args['videoId']}')) {
          throw const CommunityException('input');
        }
        final document = await parseOfficialHtml(
          await session.get(
            _web('/animeVideo.php', {'sn': '${args['videoId']}'}),
          ),
        );
        final onclick =
            document
                .querySelector('.anime_name [onclick*="toggleGather"]')
                ?.attributes['onclick'] ??
            '';
        final image = document.querySelector('.data-img');
        final anime = <String, dynamic>{
          'id': _gather.firstMatch(onclick)?[2],
          'title': document
              .querySelector('.anime_name h1')
              ?.text
              .trim()
              .replaceFirst(_episodeSuffix, ''),
          'cover': _image(
            image?.attributes['data-src'] ?? image?.attributes['src'],
          ),
          'latestVideoId': '${args['videoId']}',
          'sections': <String>[],
        };
        result = {'ok': true, 'anime': Anime.fromJson(anime)};
      case 'comment-send':
        if (!_videoId.hasMatch('${args['videoId']}') ||
            !_id.hasMatch('${args['messageId']}') ||
            (args['commentId'] != null &&
                !_id.hasMatch('${args['commentId']}')) ||
            args['text'] is! String) {
          throw const CommunityException('input');
        }
        final trimmed = (args['text'] as String).trim();
        if (trimmed.isEmpty || trimmed.runes.length > 2000) {
          throw const CommunityException('input');
        }
        if (session.cookies.header(_web('/mygather.php')).isEmpty) {
          throw const CommunityException('login');
        }
        final (_, board) = await (
          _requireProfile(session, owner),
          session.json(
            _wall('v2/comment_detail.php', {
              'service': '4',
              'serviceId': '${args['videoId']}',
              'order': '1',
            }),
          ),
        ).waitWithOriginalError();
        if ('${board['messageId']}' != args['messageId']) {
          throw const CommunityException('stale');
        }
        final body =
            jsonDecode(
                  await session.post(_wall('v1/comment_new.php'), {
                    'messageId': '${args['messageId']}',
                    if (args['commentId'] != null)
                      'commentId': '${args['commentId']}',
                    'message': trimmed,
                  }, headers: session.csrfHeaders()),
                )
                as Json;
        if (!_id.hasMatch('${body['commentId']}') ||
            _error(body['message']) ||
            _error(body['error'])) {
          throw const CommunityException('rejected');
        }
        return {'ok': true, 'id': '${body['commentId']}'};
      case 'comment-vote':
        if (!_id.hasMatch('${args['commentId']}') ||
            !const [1, 2].contains(args['type']) ||
            args['remove'] is! bool) {
          throw const CommunityException('input');
        }
        await _requireProfile(session, owner);
        final body =
            jsonDecode(
                  await session.post(
                    _wall(
                      args['remove'] == true
                          ? 'v1/comment_like_del.php'
                          : 'v1/comment_like.php',
                    ),
                    {
                      'commentId': '${args['commentId']}',
                      'type': '${args['type']}',
                    },
                    headers: session.csrfHeaders(),
                  ),
                )
                as Json;
        if (_error(body['message']) || _error(body['error'])) {
          throw const CommunityException('rejected');
        }
        return {'ok': true};
      default:
        throw const CommunityException('input');
    }
    await session.revalidate();
    return result;
  }, checkCurrent: checkCurrent);

  static bool _error(dynamic value) =>
      value != null && value != false && value != 0 && value != '';

  static int _integer(dynamic value, {int minimum = 0}) {
    if (value == null || value == '') return 0;
    final parsed =
        value is String && value.length <= 10 && _integerText.hasMatch(value)
        ? int.tryParse(value)
        : value;
    if (parsed is! int || parsed < minimum || parsed > 100000000) {
      throw const CommunityException('format');
    }
    return parsed;
  }

  static List<OfficialComment> _comments(dynamic raw, {int maxItems = 200}) {
    if (raw is! List || raw.length > maxItems) {
      throw const CommunityException('format');
    }
    final result = <OfficialComment>[];
    final ids = <String>{};
    for (final value in raw) {
      final row = value as Json;
      final vote = _integer(row['isLike'], minimum: -100000000);
      final image = row['image'];
      if (image != null &&
          image is! Json &&
          !(image is List && image.isEmpty)) {
        throw const CommunityException('format');
      }
      final replies = row['commentCount'];
      final item = <String, dynamic>{
        'id': '${row['id']}',
        'name': row['name'],
        'userId': '${row['userid']}',
        'text': row['text'] ?? '',
        'time': '${row['time'] ?? ''}',
        'avatar': _image(row['propic'] as String?),
        'image': _image(image is Json ? image['B'] as String? : null),
        'likes': _integer(row['likeCount']),
        'dislikes': _integer(row['dislikeCount']),
        'replies': _integer(
          replies == null || replies == '' ? row['children'] : replies,
        ),
        'vote': vote.sign,
        'folded': row['isFolded'] == true,
      };
      final comment = OfficialComment.fromJson(item);
      if (!ids.add(comment.id)) throw const CommunityException('format');
      result.add(comment);
    }
    return result;
  }

  void invalidate() => transport.invalidate();
  void dispose() => transport.dispose();
}

Model? _originalModel<Model>(Json raw) =>
    raw is _ModelProjection<Model> && raw._json == null ? raw.model : null;

class _ModelProjection<Model> extends MapBase<String, dynamic> {
  _ModelProjection(this.model, this._serialize);

  final Model model;
  final Json Function(Model) _serialize;
  Json? _json;
  Json get _map => _json ??= _serialize(model);

  @override
  dynamic operator [](Object? key) => _map[key];

  @override
  void operator []=(String key, dynamic value) => _map[key] = value;

  @override
  void clear() => _map.clear();

  @override
  Iterable<String> get keys => _map.keys;

  @override
  dynamic remove(Object? key) => _map.remove(key);
}

extension _PairWait<First, Second> on (Future<First>, Future<Second>) {
  Future<(First, Second)> waitWithOriginalError() async {
    final values = await Future.wait<Object?>([$1, $2], eagerError: true);
    return (values[0] as First, values[1] as Second);
  }
}

extension _TripleWait<First, Second, Third>
    on (Future<First>, Future<Second>, Future<Third>) {
  Future<(First, Second, Third)> waitWithOriginalError() async {
    final values = await Future.wait<Object?>([$1, $2, $3], eagerError: true);
    return (values[0] as First, values[1] as Second, values[2] as Third);
  }
}
