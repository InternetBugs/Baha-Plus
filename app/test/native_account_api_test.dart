import 'fake_playback.dart';
import 'dart:async';
import 'dart:convert';

import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_account_api.dart';
import 'package:baha_plus/data/native_http_api.dart';
import 'package:baha_plus/data/official_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'fake_metadata.dart';
import 'fake_account.dart';

const accountAnime = Anime(
  id: '10',
  title: '測試動畫',
  cover: 'https://p2.bahamut.com.tw/10.jpg',
  latestVideoId: '20',
);
const nativeProfile = {'id': 'reader', 'displayName': '讀者'};
const logoutToken = 'test-logout-confirmation-token';
const logoutConfirmation =
    '''
<script>
function logout() {
  var f = document.createElement('form');
  f.method = 'POST';
  f.action = 'logout.php';
  var input = document.createElement('input');
  input.name = 'token';
  input.type = 'hidden';
  input.value = '$logoutToken';
  f.appendChild(input);
  document.body.append(f);
  f.submit();
}
</script>
''';
Matcher nativeError(String code) =>
    isA<CommunityException>().having((e) => e.code, 'code', code);

class AccountFixture {
  String owner = 'reader', cookie = 'session-a';
  bool saved = false, paginate = false, live = true, scriptedMenu = true;
  int cookieReads = 0;
  int cookieClears = 0;
  Duration timeout = const Duration(seconds: 12);
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? handler;

  String profile() => scriptedMenu
      ? '''
<a class="user-info"><span class="user-id">$owner</span>
<span class="user-name">讀者</span></a><h2 class="theme-title">我的動畫</h2>
'''
      : '''
<h2 class="theme-title">我的動畫</h2>
<a href="/viewList.php?u=$owner">觀看紀錄</a>
''';
  String card() => '''
<a class="theme-list-main" href="/animeRef.php?sn=10">
<span class="theme-name">測試動畫</span>
<img class="theme-img" src="https://p2.bahamut.com.tw/10.jpg">
<button onclick="animefun.toggleGather(900, 10, this, 'ordered')"></button></a>
''';
  Json rawComment(String id) => {
    'id': id,
    'name': '讀者',
    'userid': 'reader',
    'text': '原生留言',
    'time': '1天前',
    'likeCount': 3,
    'isLike': 1,
    'isFolded': id == '2',
  };
  Future<NativeHttpCookieJar> cookies() async {
    cookieReads++;
    final jar = NativeHttpCookieJar(allowedHosts: OfficialHttpClient.hosts);
    if (cookie.isNotEmpty) {
      jar.receive(
        Uri.https('ani.gamer.com.tw', '/'),
        'session=$cookie; Domain=gamer.com.tw; Path=/; Secure; HttpOnly',
      );
      jar.receive(
        Uri.https('wall.gamer.com.tw', '/'),
        'wallSession=wall; Path=/; Secure; HttpOnly',
      );
    }
    return jar;
  }

  http.Response response(http.Request request) {
    final text = switch (request.url.path) {
      '/mygather.php' =>
        '${profile()}${saved ? card() : ''}'
            '${paginate ? '<div class="page_number"><a href="?page=2">2</a></div>' : ''}',
      '/anime/v3/history.php' => jsonEncode({
        'data': {
          'totalPage': 1,
          'history': [
            {
              'animeSn': 10,
              'videoSn': 20,
              'title': '測試動畫',
              'episode': '1',
              'cover': accountAnime.cover,
              'duration': 24,
              'breakPoint': {'breakPoint': 720},
              'nextVideoSn': 21,
              'watchTime': '2026-11-13T08:00:00Z',
            },
            {'isTakenDown': 1},
          ],
        },
      }),
      '/search.php' =>
        '''
<button class="${saved ? 'ordered' : ''}"
 onclick="animefun.toggleGather(900, 10, this, 'ordered')"></button>
''',
      '/ajax/getCSRFToken.php' => 'test-csrf',
      '/ajax/want2play.php' => '<response><okMsg>OK</okMsg></response>',
      '/ajax/delgather.php' => '{"error":0}',
      '/app/v2/comment_detail.php' => jsonEncode({
        'messageId': 123,
        'commentCount': 2,
        'nextPage': 4,
        'comments': [rawComment('1'), rawComment('2')],
      }),
      '/app/v1/reply_detail.php' => jsonEncode({
        'comments': [rawComment('3')],
      }),
      '/app/v1/comment_new.php' => '{"commentId":91}',
      '/app/v1/comment_like.php' || '/app/v1/comment_like_del.php' => '{}',
      '/ajax/common/topBar.php' =>
        '''
<li><a href="https://ani.gamer.com.tw/animeVideo.php?sn=20">
<img src="${accountAnime.cover}">測試動畫更新<small>1天前</small></a></li>
<a href="https://attacker.test/animeVideo.php?sn=99">外站</a>
''',
      '/animeVideo.php' =>
        '''
<div class="anime_name"><h1>測試動畫 [1]</h1>
<button onclick="animefun.toggleGather(900, 10, this)"></button></div>
<img class="data-img" src="${accountAnime.cover}">
''',
      _ => throw StateError('Unexpected endpoint ${request.url.path}'),
    };
    return http.Response(
      text,
      200,
      headers: {'content-type': 'text/plain; charset=utf-8'},
    );
  }

  late final api = NativeAccountApi(
    transport: OfficialHttpClient(
      cookieLoader: cookies,
      cookieClearer: () async {
        cookieClears++;
        cookie = '';
      },
      timeout: timeout,
      client: MockClient((request) async {
        requests.add(request);
        final result = handler == null
            ? response(request)
            : await handler!(request);
        if (request.url.path == '/ajax/want2play.php') saved = true;
        if (request.url.path == '/ajax/delgather.php') saved = false;
        return result;
      }),
    ),
  );

  void check() {
    if (!live) throw const CommunityException('stale');
  }

  Future<Json> community(String action, [Json args = const {}]) =>
      api.community(action, args, checkCurrent: check);
  Iterable<http.Request> get posts => requests.where((r) => r.method == 'POST');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'logout reads the confirmation token and posts it before clearing device cookies',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async {
        expect(request.url, OfficialSite.logout);
        expect(request.headers['cookie'], 'session=session-a');
        expect(request.headers['origin'], OfficialSite.logout.origin);
        expect(request.headers['referer'], OfficialSite.logout.toString());
        expect(fixture.cookieClears, 0);
        expect(request.followRedirects, isFalse);
        if (request.method == 'GET') {
          return http.Response(logoutConfirmation, 200);
        }
        expect(request.method, 'POST');
        expect(request.bodyFields, {'token': logoutToken});
        return http.Response(
          '',
          302,
          headers: {'location': 'https://www.gamer.com.tw/'},
        );
      };
      await fixture.api.logout();
      expect(fixture.requests, hasLength(2));
      expect(fixture.cookieClears, 1);
      expect(fixture.cookie, isEmpty);
    },
  );

  for (final status in [200, 500]) {
    test('logout clears device cookies after HTTP $status', () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async => http.Response(
        request.method == 'GET' ? logoutConfirmation : '',
        request.method == 'GET' ? 200 : status,
      );
      if (status == 200) {
        await fixture.api.logout();
      } else {
        await expectLater(
          fixture.api.logout(),
          throwsA(nativeError('unavailable')),
        );
      }
      expect(fixture.cookieClears, 1);
      expect(fixture.cookie, isEmpty);
    });
  }

  for (final method in ['GET', 'POST']) {
    test('logout clears device cookies when $method times out', () async {
      final fixture = AccountFixture()
        ..timeout = const Duration(milliseconds: 20);
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async {
        if (request.method != method) {
          return http.Response(logoutConfirmation, 200);
        }
        return Completer<http.Response>().future;
      };
      await expectLater(fixture.api.logout(), throwsA(nativeError('network')));
      expect(fixture.cookieClears, 1);
      expect(fixture.cookie, isEmpty);
    });
  }

  test(
    'logout refuses an external redirect and still clears device cookies',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (_) async => http.Response(
        '',
        302,
        headers: {'location': 'https://attacker.test/'},
      );
      await expectLater(
        fixture.api.logout(),
        throwsA(nativeError('unavailable')),
      );
      expect(fixture.requests, hasLength(1));
      expect(fixture.cookieClears, 1);
    },
  );

  test('logout never posts without a valid confirmation token', () async {
    final fixture = AccountFixture();
    addTearDown(fixture.api.dispose);
    fixture.handler = (_) async =>
        http.Response('<h1>Confirm logout</h1>', 200);
    await expectLater(fixture.api.logout(), throwsA(nativeError('format')));
    expect(fixture.posts, isEmpty);
    expect(fixture.cookieClears, 1);
  });

  test(
    'logout supports an official confirmation form and login redirect',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async {
        if (request.method == 'GET') {
          return http.Response(
            '<form method="post" action="logout.php">'
            '<input name="token" value="$logoutToken"></form>',
            200,
          );
        }
        expect(request.bodyFields, {'token': logoutToken});
        return http.Response(
          '',
          302,
          headers: {'location': 'https://user.gamer.com.tw/login.php'},
        );
      };
      await fixture.api.logout();
      expect(fixture.cookieClears, 1);
    },
  );

  test(
    'profile refresh reads current public data without sending cookies',
    () async {
      final fixture = AccountFixture()..scriptedMenu = false;
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async {
        if (request.url.host != 'home.gamer.com.tw') {
          return fixture.response(request);
        }
        return http.Response(
          '''
<img id="avatar_img" src="https://avatar2.bahamut.com.tw/reader.png">
<div class="main-container_header_info"><h1>新暱稱</h1>
<div class="header_info-small"><small>ID：reader</small></div></div>
''',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      };
      expect(await fixture.api.fetchProfile(), {
        'id': 'reader',
        'displayName': '新暱稱',
        'avatar': 'https://avatar2.bahamut.com.tw/reader.png',
      });
      expect(fixture.requests.map((r) => r.url.path), [
        '/mygather.php',
        '/profile/index.php',
      ]);
      final publicRequest = fixture.requests.last;
      expect(publicRequest.url.queryParameters, {'owner': 'reader'});
      expect(publicRequest.headers.containsKey('cookie'), isFalse);
      expect(fixture.posts, isEmpty);
    },
  );

  test('guest profile refresh makes no HTTP requests', () async {
    final fixture = AccountFixture()..cookie = '';
    addTearDown(fixture.api.dispose);
    expect(await fixture.api.fetchProfile(), isNull);
    expect(fixture.requests, isEmpty);
  });

  test(
    'profile refresh revalidates the login after reading public data',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async {
        if (request.url.host != 'home.gamer.com.tw') {
          return fixture.response(request);
        }
        fixture.cookie = 'switched-account';
        return http.Response(
          '''
<img id="avatar_img" src="https://avatar2.bahamut.com.tw/reader.png">
<div class="main-container_header_info"><h1>新暱稱</h1>
<div class="header_info-small"><small>ID：reader</small></div></div>
''',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      };
      await expectLater(
        fixture.api.fetchProfile(),
        throwsA(nativeError('stale')),
      );
    },
  );

  test(
    'native account reads paginate, deduplicate and preserve cloud progress',
    () async {
      final fixture = AccountFixture()
        ..saved = true
        ..paginate = true;
      addTearDown(fixture.api.dispose);
      final result = (await fixture.api.fetchAccount())!;
      expect(result['profile'], containsPair('id', 'reader'));
      expect(result['favorites'], hasLength(1));
      final history = WatchEntry.fromJson(
        (result['history'] as List).single as Json,
      );
      expect(history.videoId, '20');
      expect(history.nextVideoId, '21');
      expect(history.progress, .5);
      expect(history.progressLabel, '12:00');
      expect(
        fixture.requests.where((r) => r.url.path == '/mygather.php'),
        hasLength(2),
      );
      expect(fixture.requests.every((r) => !r.followRedirects), isTrue);
      expect(fixture.requests.first.headers['cookie'], 'session=session-a');
    },
  );

  test(
    'guest account returns empty without mounting a browser or making a request',
    () async {
      final fixture = AccountFixture()..cookie = '';
      addTearDown(fixture.api.dispose);
      expect(await fixture.api.fetchAccount(), isNull);
      expect(fixture.requests, isEmpty);
    },
  );

  test('HTTP identity is confirmed before optional history finishes', () async {
    final fixture = AccountFixture()..scriptedMenu = false;
    addTearDown(fixture.api.dispose);
    final waiting = Completer<void>(), history = Completer<http.Response>();
    fixture.handler = (request) async {
      if (request.url.path == '/anime/v3/history.php') {
        waiting.complete();
        return history.future;
      }
      return fixture.response(request);
    };
    final store = await AppStore.create(
      storage: MemoryStorage(),
      metadataApi: FakeMetadata(),
      animeSearch: FakeSearch(),
      accountApi: fixture.api,
    );
    addTearDown(store.dispose);
    final reading = store.syncAccount();
    await waiting.future;
    expect(store.accountProfile?.id, 'reader');
    expect(store.hasAccount, isTrue);
    expect(store.accountLoading, isTrue);
    expect(store.accountSynced, isFalse);
    history.complete(http.Response('', 503));
    await reading;
    expect(store.accountProfile?.id, 'reader');
    expect(store.hasAccount, isTrue);
    expect(store.accountSynced, isFalse);
    expect(store.accountNeedsRefresh, isTrue);
    expect(store.notice, store.t('accountSyncError'));
  });

  test('server identity paginates and syncs without a scripted menu', () async {
    final fixture = AccountFixture()
      ..scriptedMenu = false
      ..saved = true
      ..paginate = true;
    addTearDown(fixture.api.dispose);
    final account = (await fixture.api.fetchAccount())!;
    expect(account['profile'], containsPair('id', 'reader'));
    expect(account['favorites'], hasLength(1));
    expect(account['history'], hasLength(1));
  });

  test(
    'unrelated redirects preserve the known account and never follow',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (_) async =>
          http.Response('', 302, headers: {'location': '/maintenance.php'});
      final store = await AppStore.create(
        storage: MemoryStorage(),
        metadataApi: FakeMetadata(),
        animeSearch: FakeSearch(),
        accountApi: fixture.api,
      );
      addTearDown(store.dispose);
      store.accountProfile = AccountProfile.fromJson(nativeProfile);
      store.accountSynced = true;
      await store.syncAccount();
      expect(store.accountProfile?.id, 'reader');
      expect(store.accountSynced, isTrue);
      expect(fixture.requests.single.followRedirects, isFalse);
    },
  );

  test(
    'confirmed login survives a temporarily unavailable native session',
    () async {
      final api = FakeAccountApi()..accountLoader = () async => null;
      final store = await AppStore.create(
        storage: MemoryStorage(),
        metadataApi: FakeMetadata(),
        animeSearch: FakeSearch(),
        accountApi: api,
      );
      addTearDown(store.dispose);
      await store.attach(FakePortal());
      await store.connectAccount();
      await store.receive(
        jsonEncode({
          'type': 'account-authenticated',
          'requestId': store.operation.id,
          'profile': nativeProfile,
        }),
        origin: OfficialSite.home,
        source: OfficialSite.home.resolve('mygather.php'),
        isMainFrame: true,
      );
      expect(store.accountProfile?.id, 'reader');
      expect(store.hasAccount, isTrue);
      expect(store.accountNeedsRefresh, isTrue);
      expect(store.accountSynced, isFalse);
      expect(store.browserVisible, isFalse);
      // A subsequent independently confirmed guest refresh can clear identity.
      await store.syncAccount();
      expect(store.hasAccount, isFalse);
    },
  );

  test(
    'expected login owner rejects missing cookies or another account',
    () async {
      final fixture = AccountFixture()..cookie = '';
      addTearDown(fixture.api.dispose);
      await expectLater(
        fixture.api.fetchAccount(expectedOwner: 'reader'),
        throwsA(nativeError('login')),
      );
      fixture.cookie = 'session-a';
      fixture.owner = 'another';
      await expectLater(
        fixture.api.fetchAccount(expectedOwner: 'reader'),
        throwsA(nativeError('stale')),
      );
      expect(fixture.requests, hasLength(1));
    },
  );

  test(
    'public comments and replies preserve order, voting and folded rows',
    () async {
      final fixture = AccountFixture()..cookie = '';
      addTearDown(fixture.api.dispose);
      final page = CommentPage.fromJson(
        await fixture.community('comments', {
          'videoId': '20',
          'order': 0,
          'page': 3,
        }),
      );
      expect(page.comments.map((c) => c.id), ['2', '1']);
      expect(page.comments.first.folded, isTrue);
      expect(page.comments.first.vote, 1);
      expect(fixture.requests.single.url.queryParameters, {
        'service': '4',
        'serviceId': '20',
        'order': '0',
        'nextPage': '3',
      });
      final replies = await fixture.community('replies', {'commentId': '1'});
      expect((replies['comments'] as List).single['id'], '3');
      expect(
        fixture.requests.every((r) => !r.headers.containsKey('cookie')),
        isTrue,
      );
    },
  );

  test(
    'official numeric strings and empty image arrays remain valid comments',
    () async {
      final fixture = AccountFixture()..cookie = '';
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async => http.Response(
        jsonEncode({
          'messageId': '123',
          'commentCount': '2',
          'nextPage': '0',
          'comments': [
            {
              ...fixture.rawComment('1'),
              'likeCount': '3',
              'dislikeCount': '0',
              'commentCount': '2',
              'isLike': '-1',
              'image': [],
            },
            {
              ...fixture.rawComment('2'),
              'commentCount': '',
              'children': '1',
              'image': {'B': accountAnime.cover},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
      final page = CommentPage.fromJson(
        await fixture.community('comments', {
          'videoId': '20',
          'order': 1,
          'page': 0,
        }),
      );
      expect(page.total, 2);
      expect(page.nextPage, 0);
      expect(page.comments.first.image, accountAnime.cover);
      expect(page.comments.first.replies, 1);
      expect(page.comments.last.image, isNull);
      expect(page.comments.last.likes, 3);
      expect(page.comments.last.replies, 2);
      expect(page.comments.last.vote, -1);
      final replies = await fixture.community('replies', {'commentId': '1'});
      expect((replies['comments'] as List).first['replies'], 2);
    },
  );

  test('malformed comment counts and attachment arrays are rejected', () async {
    for (final invalid in [
      {'commentCount': 'unknown'},
      {'likeCount': -1},
      {'dislikeCount': 1.5},
      {'children': 100000001},
      {
        'image': [accountAnime.cover],
      },
    ]) {
      final fixture = AccountFixture()..cookie = '';
      addTearDown(fixture.api.dispose);
      fixture.handler = (_) async => http.Response(
        jsonEncode({
          'comments': [
            {...fixture.rawComment('1'), ...invalid},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
      await expectLater(
        fixture.community('replies', {'commentId': '1'}),
        throwsA(nativeError('format')),
      );
    }
  });

  test(
    'favorite sends the real pair of series IDs once and respects desired state',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      Future<void> set(bool desired) => fixture.api.setFavorite(
        accountAnime,
        desired,
        owner: 'reader',
        checkCurrent: fixture.check,
      );
      await set(true);
      expect(fixture.posts.single.url.path, '/ajax/want2play.php');
      expect(fixture.posts.single.bodyFields, {
        's': '900',
        'animeSn': '10',
        'token': 'test-csrf',
      });
      await set(true);
      expect(fixture.posts, hasLength(1));
      await set(false);
      expect(fixture.posts.last.url.path, '/ajax/delgather.php');
      expect(fixture.posts, hasLength(2));
    },
  );

  test(
    'native comment writes recheck board ownership and reproduce official CSRF',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      final result = await fixture.community('comment-send', {
        'owner': 'reader',
        'videoId': '20',
        'messageId': '123',
        'commentId': '2',
        'text': ' 回覆 & <文字> ',
      });
      expect(result['id'], '91');
      final post = fixture.posts.single;
      expect(post.url.host, 'wall.gamer.com.tw');
      expect(post.bodyFields, {
        'messageId': '123',
        'commentId': '2',
        'message': '回覆 & <文字>',
      });
      final csrf = post.headers['x-bahamut-csrf-token']!;
      expect(csrf, matches(RegExp(r'^[a-f0-9]{16}$')));
      expect(post.headers['cookie'], contains('ckBahamutCsrfToken=$csrf'));
      expect(post.headers['cookie'], contains('wallSession=wall'));
      expect(post.headers['cookie'], contains('session=session-a'));
    },
  );

  test('vote and undo use separate official endpoints', () async {
    final fixture = AccountFixture();
    addTearDown(fixture.api.dispose);
    for (final remove in [false, true]) {
      await fixture.community('comment-vote', {
        'owner': 'reader',
        'commentId': '1',
        'type': 2,
        'remove': remove,
      });
    }
    expect(fixture.posts.map((r) => r.url.path), [
      '/app/v1/comment_like.php',
      '/app/v1/comment_like_del.php',
    ]);
  });

  for (final change in ['cookie', 'owner', 'document', 'board']) {
    test(
      '$change change before a comment submission prevents all writes',
      () async {
        final fixture = AccountFixture();
        addTearDown(fixture.api.dispose);
        fixture.handler = (request) async {
          final response = fixture.response(request);
          if (request.url.path.endsWith('comment_detail.php')) {
            if (change == 'cookie') fixture.cookie = 'session-b';
            if (change == 'document') fixture.live = false;
            if (change == 'board') {
              return http.Response('{"messageId":999}', 200);
            }
          }
          return response;
        };
        if (change == 'owner') fixture.owner = 'another';
        await expectLater(
          fixture.community('comment-send', {
            'owner': 'reader',
            'videoId': '20',
            'messageId': '123',
            'text': '測試',
          }),
          throwsA(nativeError('stale')),
        );
        expect(fixture.posts, isEmpty);
      },
    );
  }

  test(
    'successful POST stays successful after navigation while receiving acknowledgement',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async {
        if (request.method == 'POST') fixture.live = false;
        return fixture.response(request);
      };
      expect(
        (await fixture.community('comment-send', {
          'owner': 'reader',
          'videoId': '20',
          'messageId': '123',
          'text': '測試',
        }))['id'],
        '91',
      );
      expect(fixture.posts, hasLength(1));
    },
  );

  test(
    'notifications deduplicate official links and resolve series independently of video ID',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      final result = await fixture.community('notifications', {
        'owner': 'reader',
      });
      expect(result['owner'], 'reader');
      final notification = AnimeNotification.fromJson(
        (result['items'] as List).single as Json,
      );
      expect(notification.title, '測試動畫更新');
      expect(notification.videoId, '20');
      expect(notification.time, '1天前');
      final target = await fixture.community('notification-target', {
        'videoId': '20',
      });
      expect(Anime.fromJson(target['anime'] as Json).id, '10');
    },
  );

  test('notifications ignore official top-bar JavaScript actions', () async {
    final fixture = AccountFixture();
    addTearDown(fixture.api.dispose);
    fixture.handler = (request) async {
      if (request.url.path != '/ajax/common/topBar.php') {
        return fixture.response(request);
      }
      // Structure verified against the signed-in official top bar:
      // episode links share a div with a javascript: notification action.
      return http.Response(
        request.url.queryParameters['type'] == 'light_0'
            ? '''
<div>
<a href="https://ani.gamer.com.tw/animeVideo.php?sn=20" target="_blank">
<span class="TOP-msgpic"><img src="${accountAnime.cover}"></span>
<p class="title"><span class="link">測試動畫 [1] 更新囉！</span></p>
<div><span class="time">1天前</span></div>
</a>
<a class="msg-ellipsis" href="javascript:NOTIFY_follow('4', '123', 0)"></a>
</div>
<a href="https://home.gamer.com.tw/login_bad_log.php">帳號通知</a>
'''
            : '''
<div><a href="https://gnn.gamer.com.tw/detail.php?sn=123">新聞</a>
<a class="msg-ellipsis" href="javascript:NOTIFY_follow('4', '456', 0)"></a>
</div>
''',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    };
    final result = await fixture.community('notifications', {
      'owner': 'reader',
    });
    final notification = AnimeNotification.fromJson(
      (result['items'] as List).single as Json,
    );
    expect(notification.videoId, '20');
    expect(notification.title, '測試動畫 [1] 更新囉！');
    expect(notification.time, '1天前');
    expect(notification.cover, accountAnime.cover);
    expect(fixture.posts, isEmpty);
  });

  test(
    'notifications keep image-link titles and ignore invalid episode targets',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (request) async {
        if (request.url.path != '/ajax/common/topBar.php') {
          return fixture.response(request);
        }
        return http.Response(
          '''
<li><a href="/animeVideo.php?sn=21" title=" 測試動畫 [2] 更新囉！ ">
<img src="${accountAnime.cover}"></a><small>今天</small></li>
<a href="javascript:void(0)">操作</a>
<a href="mailto:notice@example.test">信箱</a>
<a href="https://[">無效網址</a>
<a href="https://ani.gamer.com.tw.attacker.test/animeVideo.php?sn=99">外站</a>
<a href="https://attacker@ani.gamer.com.tw/animeVideo.php?sn=99">偽造</a>
<a href="https://ani.gamer.com.tw:444/animeVideo.php?sn=99">錯誤連接埠</a>
<a href="/animeVideo.php?sn=20&amp;sn=99">不明集數</a>
<a href="/animeVideo.php?sn=0">無效集數</a>
''',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      };
      final result = await fixture.community('notifications', {
        'owner': 'reader',
      });
      final notification = AnimeNotification.fromJson(
        (result['items'] as List).single as Json,
      );
      expect(notification.videoId, '21');
      expect(notification.title, '測試動畫 [2] 更新囉！');
      expect(notification.time, '今天');
      expect(notification.cover, accountAnime.cover);
    },
  );

  test(
    'official challenges, redirects and oversized responses do not become account data',
    () async {
      for (final response in [
        http.Response(
          '<script src="/cdn-cgi/challenge-platform/x"></script>',
          200,
        ),
        http.Response('', 302, headers: {'location': 'https://attacker.test/'}),
        http.Response('x' * 2000001, 200),
      ]) {
        final fixture = AccountFixture();
        addTearDown(fixture.api.dispose);
        fixture.handler = (_) async => response;
        await expectLater(
          fixture.community('comments', {
            'videoId': '20',
            'order': 1,
            'page': 0,
          }),
          throwsA(isA<CommunityException>()),
        );
        expect(fixture.requests, hasLength(1));
      }
    },
  );

  test('login invalidation rejects a late account result', () async {
    final fixture = AccountFixture();
    addTearDown(fixture.api.dispose);
    final gate = Completer<http.Response>(), waiting = Completer<void>();
    fixture.handler = (request) async {
      waiting.complete();
      return gate.future;
    };
    final reading = fixture.api.fetchAccount();
    final rejected = expectLater(reading, throwsA(isA<CommunityException>()));
    await waiting.future;
    fixture.api.invalidate();
    gate.complete(
      http.Response(
        fixture.profile(),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      ),
    );
    await rejected;
  });

  test(
    'a stale unauthorized response cannot clear a newly switched account',
    () async {
      final fixture = AccountFixture();
      addTearDown(fixture.api.dispose);
      fixture.handler = (_) async {
        fixture.cookie = 'new-account-session';
        return http.Response('', 401);
      };
      await expectLater(
        fixture.api.fetchAccount(),
        throwsA(nativeError('stale')),
      );
    },
  );

  test(
    'an earlier account refresh cannot overwrite a confirmed favorite',
    () async {
      final api = FakeAccountApi();
      final pending = Completer<Json?>();
      api.accountLoader = () => pending.future;
      api.favoriteHandler = (_, _) async {};
      final store = await AppStore.create(
        nativeHttpApiFactory: PendingNativeHttpApi.new,
        storage: MemoryStorage(),
        metadataApi: FakeMetadata(),
        animeSearch: FakeSearch(),
        accountApi: api,
      );
      addTearDown(store.dispose);
      store.accountProfile = AccountProfile.fromJson(nativeProfile);
      final reading = store.syncAccount();
      await store.toggleFavorite(accountAnime);
      pending.complete({
        'profile': nativeProfile,
        'favorites': [],
        'history': [],
      });
      await reading;
      expect(store.isFavorite(accountAnime), isTrue);
      expect(store.accountLoading, isFalse);
      expect(store.accountNeedsRefresh, isTrue);
    },
  );

  test(
    'store refresh, comments, notifications and favorites never navigate or change playback ticket',
    () async {
      final fixture = AccountFixture()..saved = true;
      final store = await AppStore.create(
        nativeHttpApiFactory: PendingNativeHttpApi.new,
        storage: MemoryStorage(),
        metadataApi: FakeMetadata(),
        animeSearch: FakeSearch(),
        accountApi: fixture.api,
      );
      addTearDown(store.dispose);
      final portal = FakePortal();
      await store.attach(portal);
      final document = store.operation.id;
      await store.syncAccount();
      await store.loadComments('20');
      await store.refreshNotifications();
      await store.toggleFavorite(accountAnime);
      await Future<void>.delayed(Duration.zero);
      expect(store.operation.id, document);
      expect(store.accountProfile?.id, 'reader');
      expect(store.favorites, isEmpty);
      expect(portal.visited, isEmpty);
      expect(portal.scripts, isEmpty);
      expect(portal.communityRequests, isEmpty);
      expect(store.needsOfficialPortal, isFalse);
    },
  );
}
