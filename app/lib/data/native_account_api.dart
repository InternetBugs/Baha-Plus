import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;

import '../core/community.dart';
import '../core/models.dart';
import 'official_http_client.dart';

/// Official account, collection and community endpoints, executed in Dart.
/// The collection/profile endpoints return HTML; it is parsed as inert data.
/// All account cookies remain in the per-operation HTTP session.
class NativeAccountApi {
  NativeAccountApi({OfficialHttpClient? transport})
    : transport = transport ?? OfficialHttpClient();

  final OfficialHttpClient transport;
  static final _id = RegExp(r'^[1-9][0-9]{0,19}$');
  static final _videoId = RegExp(r'^[1-9][0-9]{0,9}$');
  static final _gather = RegExp(r'toggleGather\(\s*(\d+)\s*,\s*(\d+)\s*,');
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

  static Json? _profile(Document page) {
    final user = page.querySelector('a.user-info');
    final id = user?.querySelector('.user-id')?.text.trim();
    if (id == null || id.isEmpty || id.toLowerCase() == 'guest') {
      if (page.querySelector('a[href*="user.gamer.com.tw/login.php"]') !=
          null) {
        return null;
      }
      throw const CommunityException('format');
    }
    final img = user?.querySelector('.avatar img');
    final profile = <String, dynamic>{
      'id': id,
      'displayName': user?.querySelector('.user-name')?.text.trim() ?? id,
      'avatar': _image(img?.attributes['data-src'] ?? img?.attributes['src']),
    };
    AccountProfile.fromJson(profile);
    return profile;
  }

  Future<Json> _requireProfile(
    OfficialHttpSession session,
    String? expectedOwner,
  ) async {
    final profile = _profile(parse(await session.get(_web('/mygather.php'))));
    if (profile == null) throw const CommunityException('login');
    if (expectedOwner != null &&
        (profile['id'] as String).toLowerCase() !=
            expectedOwner.toLowerCase()) {
      throw const CommunityException('stale');
    }
    return profile;
  }

  Future<Json?> fetchAccount({
    void Function()? checkCurrent,
  }) => transport.session((session) async {
    if (session.cookies.header(_web('/mygather.php')).isEmpty) return null;
    Document page;
    try {
      page = parse(await session.get(_web('/mygather.php')));
    } on CommunityException catch (error) {
      if (error.code == 'login') return null;
      rethrow;
    }
    final profile = _profile(page);
    if (profile == null) return null;
    final owner = (profile['id'] as String).toLowerCase();
    final favorites = <String, Json>{};
    final visited = <String>{};
    final queue = <Uri>[_web('/mygather.php')];
    while (queue.isNotEmpty) {
      final uri = queue.removeAt(0);
      if (!visited.add(uri.toString())) continue;
      if (visited.length > 50) throw const CommunityException('format');
      final document = visited.length == 1
          ? page
          : parse(await session.get(uri));
      if ((_profile(document)?['id'] as String?)?.toLowerCase() != owner) {
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
        Anime.fromJson(item);
        favorites[id] = item;
        if (favorites.length > 10000) throw const CommunityException('format');
      }
      for (final link in document.querySelectorAll('.page_number a[href]')) {
        final next = uri.resolve(link.attributes['href']!);
        if (next.origin == uri.origin &&
            next.path == '/mygather.php' &&
            next.fragment.isEmpty &&
            !visited.contains(next.toString())) {
          queue.add(next);
        }
      }
    }
    final history = await _history(session);
    await session.revalidate();
    return {
      'profile': profile,
      'favorites': favorites.values.toList(),
      'history': history,
    };
  }, checkCurrent: checkCurrent);

  Future<List<Json>> _history(OfficialHttpSession session) async {
    final records = <String, Json>{};
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
        WatchEntry.fromJson(item);
        records[id] = item;
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
    await _requireProfile(session, owner);
    final doc = parse(
      await session.get(_web('/search.php', {'keyword': anime.title})),
    );
    Element? selected;
    RegExpMatch? arguments;
    for (final button in doc.querySelectorAll('[onclick*="toggleGather"]')) {
      final match = _gather.firstMatch(button.attributes['onclick'] ?? '');
      if (match?[2] == anime.id) {
        selected = button;
        arguments = match;
        break;
      }
    }
    if (selected == null || arguments == null) {
      throw const CommunityException('unavailable');
    }
    final action = selected.attributes['onclick']!;
    final selectedClass = action.contains('btn-is-active')
        ? 'btn-is-active'
        : 'ordered';
    if (selected.classes.contains(selectedClass) == desired) {
      await session.revalidate();
      return;
    }
    final token = (await session.get(_web('/ajax/getCSRFToken.php'))).trim();
    if (token.isEmpty ||
        token.length > 500 ||
        token.contains(RegExp(r'[<>\r\n]'))) {
      throw const CommunityException('unavailable');
    }
    final response = await session.post(
      _web(desired ? '/ajax/want2play.php' : '/ajax/delgather.php'),
      {'s': arguments[1]!, 'animeSn': anime.id, 'token': token},
    );
    if (desired) {
      final xml = parse(response);
      if (xml.querySelector('errmsg') != null ||
          xml.querySelector('okmsg') == null) {
        throw const CommunityException('rejected');
      }
    } else {
      final result = jsonDecode(response) as Json;
      if (result['error'] != 0) throw const CommunityException('rejected');
    }
  }, checkCurrent: checkCurrent);

  Future<Json> community(
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
        result = {
          'ok': true,
          'messageId': '${body['messageId']}',
          'total': body['commentCount'],
          'nextPage': body['nextPage'] ?? 0,
          'comments': _comments(body['comments']).reversed.toList(),
        };
        CommentPage.fromJson(result);
      case 'replies':
        if (!_id.hasMatch('${args['commentId']}')) {
          throw const CommunityException('input');
        }
        final body = await session.json(
          _wall('v1/reply_detail.php', {'commentId': '${args['commentId']}'}),
        );
        result = {'ok': true, 'comments': _comments(body['comments'])};
      case 'notifications':
        final profile = await _requireProfile(session, owner);
        final items = <String, Json>{};
        for (final type in ['light_0', 'light_1']) {
          final document = parse(
            await session.get(
              Uri.https('api.gamer.com.tw', '/ajax/common/topBar.php', {
                'type': type,
              }),
            ),
          );
          for (final anchor in document.querySelectorAll('a[href]')) {
            final uri = _web('/').resolve(anchor.attributes['href']!);
            final videoId = uri.queryParameters['sn'];
            if (uri.origin != _web('/').origin ||
                uri.path != '/animeVideo.php' ||
                !_videoId.hasMatch(videoId ?? '')) {
              continue;
            }
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
            final title = titleNode.text.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (title.isEmpty || title.length > 500) continue;
            final image = row?.querySelector('img');
            final item = <String, dynamic>{
              'id': 'episode:$videoId',
              'title': title,
              'videoId': videoId,
              'time':
                  row?.querySelector('.time, .date, small')?.text.trim() ??
                  RegExp(
                    r'(?:\d+\s*(?:秒|分|分鐘|小時|天|日)前|昨天|今天)',
                  ).firstMatch(row?.text ?? '')?[0] ??
                  '',
              'cover': _image(
                image?.attributes['data-src'] ?? image?.attributes['src'],
              ),
            };
            AnimeNotification.fromJson(item);
            if (items.length < 200 || items.containsKey(item['id'])) {
              items[item['id'] as String] = item;
            }
          }
        }
        result = {
          'ok': true,
          'owner': (profile['id'] as String).toLowerCase(),
          'items': items.values.toList(),
        };
      case 'notification-target':
        if (!_videoId.hasMatch('${args['videoId']}')) {
          throw const CommunityException('input');
        }
        final document = parse(
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
              .replaceFirst(RegExp(r'\s*\[[^\]]+\]\s*$'), ''),
          'cover': _image(
            image?.attributes['data-src'] ?? image?.attributes['src'],
          ),
          'latestVideoId': '${args['videoId']}',
          'sections': <String>[],
        };
        Anime.fromJson(anime);
        result = {'ok': true, 'anime': anime};
      case 'comment-send':
        if (!_videoId.hasMatch('${args['videoId']}') ||
            !_id.hasMatch('${args['messageId']}') ||
            (args['commentId'] != null &&
                !_id.hasMatch('${args['commentId']}')) ||
            args['text'] is! String ||
            (args['text'] as String).trim().isEmpty ||
            (args['text'] as String).runes.length > 2000) {
          throw const CommunityException('input');
        }
        await _requireProfile(session, owner);
        final board = await session.json(
          _wall('v2/comment_detail.php', {
            'service': '4',
            'serviceId': '${args['videoId']}',
            'order': '1',
          }),
        );
        if ('${board['messageId']}' != args['messageId']) {
          throw const CommunityException('stale');
        }
        final body =
            jsonDecode(
                  await session.post(_wall('v1/comment_new.php'), {
                    'messageId': '${args['messageId']}',
                    if (args['commentId'] != null)
                      'commentId': '${args['commentId']}',
                    'message': (args['text'] as String).trim(),
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

  static List<Json> _comments(dynamic raw) {
    if (raw is! List || raw.length > 200) {
      throw const CommunityException('format');
    }
    final result = <Json>[];
    for (final value in raw) {
      final row = value as Json;
      final vote = row['isLike'] as num? ?? 0;
      final item = <String, dynamic>{
        'id': '${row['id']}',
        'name': row['name'],
        'userId': '${row['userid']}',
        'text': row['text'] ?? '',
        'time': '${row['time'] ?? ''}',
        'avatar': _image(row['propic'] as String?),
        'image': _image((row['image'] as Json?)?['B'] as String?),
        'likes': row['likeCount'] ?? 0,
        'dislikes': row['dislikeCount'] ?? 0,
        'replies': row['commentCount'] ?? row['children'] ?? 0,
        'vote': vote.sign.toInt(),
        'folded': row['isFolded'] == true,
      };
      OfficialComment.fromJson(item);
      result.add(item);
    }
    CommentPage.parseComments(result);
    return result;
  }

  void invalidate() => transport.invalidate();
  void dispose() => transport.dispose();
}
