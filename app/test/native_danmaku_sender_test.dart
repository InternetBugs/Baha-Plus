import 'dart:async';
import 'dart:convert';

import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/native_danmaku.dart';
import 'package:baha_plus/data/native_danmaku_sender.dart';
import 'package:baha_plus/data/native_http_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class DanmakuSendFixture {
  final requests = <http.Request>[];
  String cookie = 'session-a', owner = 'reader';
  double position = 37.89;
  bool live = true;
  int cookieReads = 0;
  Future<http.Response> Function(http.Request)? handler;
  Future<NativeHttpCookieJar> cookies() async {
    cookieReads++;
    final jar = NativeHttpCookieJar();
    if (cookie.isNotEmpty) {
      jar.receive(
        Uri.https('ani.gamer.com.tw', '/'),
        'session=$cookie; Domain=gamer.com.tw; Path=/; Secure; HttpOnly',
      );
    }
    return jar;
  }

  http.Response response(http.Request request) => http.Response(
    switch (request.url.path) {
      '/mygather.php' =>
        '<a class="user-info"><span class="user-id">$owner</span></a>',
      '/ajax/getCSRFToken.php' => 'offline-csrf',
      '/ajax/danmuSet.php' => '{"sn":91}',
      _ => throw StateError('Unexpected endpoint'),
    },
    200,
    headers: {'content-type': 'text/plain; charset=utf-8'},
  );

  late final sender = NativeDanmakuSender(
    cookieLoader: cookies,
    client: MockClient((request) async {
      requests.add(request);
      return handler == null ? response(request) : await handler!(request);
    }),
  );

  Future<NativeDanmaku> send({
    String text = '測試 & <原生>',
    String color = '#FFD166',
    int mode = 1,
    int size = 2,
  }) => sender.send(
    videoId: '40190',
    owner: 'reader',
    text: text,
    color: color,
    position: mode,
    size: size,
    currentPosition: () => position,
    checkCurrent: () {
      if (!live) throw const CommunityException('stale');
    },
  );

  Iterable<http.Request> get posts =>
      requests.where((request) => request.method == 'POST');
}

Matcher communityCode(String code) =>
    isA<CommunityException>().having((error) => error.code, 'code', code);

void main() {
  test(
    'native send verifies account, obtains CSRF and posts official form once',
    () async {
      final fixture = DanmakuSendFixture();
      addTearDown(fixture.sender.dispose);
      final item = await fixture.send();
      expect(fixture.cookieReads, 2);
      expect(fixture.requests.map((request) => request.url.path), [
        '/mygather.php',
        '/ajax/getCSRFToken.php',
        '/ajax/danmuSet.php',
      ]);
      final request = fixture.posts.single;
      expect(request.url.origin, 'https://ani.gamer.com.tw');
      expect(request.followRedirects, isFalse);
      expect(request.headers['cookie'], 'session=session-a');
      expect(request.headers['origin'], 'https://ani.gamer.com.tw');
      expect(request.headers['referer'], endsWith('/animeVideo.php?sn=40190'));
      expect(
        request.headers['content-type'],
        startsWith('application/x-www-form-urlencoded'),
      );
      expect(request.bodyFields, {
        'sn': '40190',
        'content': '測試 & <原生>',
        'color': '#FFD166',
        'position': '1',
        'size': '2',
        'time': '378',
        'token': 'offline-csrf',
      });
      expect(item.id, '91');
      expect(item.text, '測試 & <原生>');
      expect(item.time, 37.8);
      expect(item.mode, 'top');
      expect(item.size, 28);
    },
  );

  test(
    'current media time is sampled after CSRF rather than opening composer',
    () async {
      final fixture = DanmakuSendFixture();
      addTearDown(fixture.sender.dispose);
      fixture.handler = (request) async {
        if (request.url.path.endsWith('getCSRFToken.php')) {
          fixture.position = 42.19;
        }
        return fixture.response(request);
      };
      final item = await fixture.send();
      expect(fixture.posts.single.bodyFields['time'], '421');
      expect(item.time, 42.1);
    },
  );

  test('empty cookies, guest page and mismatched account never post', () async {
    for (final mode in ['cookies', 'guest', 'other']) {
      final fixture = DanmakuSendFixture();
      addTearDown(fixture.sender.dispose);
      if (mode == 'cookies') fixture.cookie = '';
      if (mode == 'guest') fixture.owner = '';
      if (mode == 'other') fixture.owner = 'another-account';
      await expectLater(
        fixture.send(),
        throwsA(communityCode(mode == 'other' ? 'stale' : 'login')),
      );
      expect(fixture.posts, isEmpty);
    }
  });

  test(
    'logout or account cookies changing during CSRF prevents posting',
    () async {
      final fixture = DanmakuSendFixture();
      addTearDown(fixture.sender.dispose);
      fixture.handler = (request) async {
        if (request.url.path.endsWith('getCSRFToken.php')) {
          fixture.cookie = 'other-session';
        }
        return fixture.response(request);
      };
      await expectLater(fixture.send(), throwsA(communityCode('stale')));
      expect(fixture.posts, isEmpty);
    },
  );

  test(
    'episode, advertisement or foreground invalidation during CSRF stops post',
    () async {
      final fixture = DanmakuSendFixture();
      addTearDown(fixture.sender.dispose);
      fixture.handler = (request) async {
        if (request.url.path.endsWith('getCSRFToken.php')) fixture.live = false;
        return fixture.response(request);
      };
      await expectLater(fixture.send(), throwsA(communityCode('stale')));
      expect(fixture.posts, isEmpty);
    },
  );

  test(
    'concurrent submissions are rejected before issuing a second request',
    () async {
      final fixture = DanmakuSendFixture();
      addTearDown(fixture.sender.dispose);
      final token = Completer<http.Response>();
      final waiting = Completer<void>();
      fixture.handler = (request) async {
        if (request.url.path.endsWith('getCSRFToken.php')) {
          waiting.complete();
          return token.future;
        }
        return fixture.response(request);
      };
      final first = fixture.send();
      await waiting.future;
      await expectLater(fixture.send(), throwsA(communityCode('busy')));
      token.complete(http.Response('offline-csrf', 200));
      await first;
      expect(fixture.posts.length, 1);
    },
  );

  test(
    'input validation enforces UTF-8 bytes, color and enum limits',
    () async {
      final fixture = DanmakuSendFixture();
      addTearDown(fixture.sender.dispose);
      for (final send in <Future<NativeDanmaku> Function()>[
        () => fixture.send(text: '字' * 21),
        () => fixture.send(text: '   '),
        () => fixture.send(color: 'red'),
        () => fixture.send(mode: 3),
        () => fixture.send(size: -1),
      ]) {
        await expectLater(send(), throwsA(communityCode('input')));
      }
      expect(fixture.requests, isEmpty);
      await fixture.send(text: '字' * 20);
      expect(
        utf8.encode(fixture.posts.single.bodyFields['content']!).length,
        60,
      );
    },
  );

  test(
    'server rejection, login expiry and malformed responses never acknowledge',
    () async {
      for (final (body, code) in [
        ('{"nologin":1}', 'login'),
        ('{"error":1,"sn":91}', 'rejected'),
        ('{"sn":0}', 'rejected'),
        ('{}', 'rejected'),
        ('[]', 'format'),
        ('not json', 'format'),
      ]) {
        final fixture = DanmakuSendFixture();
        addTearDown(fixture.sender.dispose);
        fixture.handler = (request) async => request.method == 'POST'
            ? http.Response(body, 200)
            : fixture.response(request);
        await expectLater(fixture.send(), throwsA(communityCode(code)));
        expect(fixture.posts.length, 1);
      }
    },
  );

  test(
    'redirects, verification and invalid tokens stop before posting',
    () async {
      for (final response in [
        http.Response('', 302, headers: {'location': 'https://other.test/'}),
        http.Response('cf-chl-challenge-platform', 200),
        http.Response('<html>login</html>', 200),
        http.Response('', 401),
      ]) {
        final fixture = DanmakuSendFixture();
        addTearDown(fixture.sender.dispose);
        fixture.handler = (request) async =>
            request.url.path.endsWith('getCSRFToken.php')
            ? response
            : fixture.response(request);
        await expectLater(fixture.send(), throwsA(isA<CommunityException>()));
        expect(fixture.posts, isEmpty);
      }
    },
  );

  test('cookies set during CSRF remain confined to the submission', () async {
    final fixture = DanmakuSendFixture();
    addTearDown(fixture.sender.dispose);
    fixture.handler = (request) async =>
        request.url.path.endsWith('getCSRFToken.php')
        ? http.Response(
            'offline-csrf',
            200,
            headers: {
              'set-cookie': 'csrf=temporary; Path=/ajax; Secure; HttpOnly',
            },
          )
        : fixture.response(request);
    await fixture.send();
    expect(fixture.posts.single.headers['cookie'], contains('csrf=temporary'));
    final original = await fixture.cookies();
    expect(
      original.header(Uri.https('ani.gamer.com.tw', '/ajax/danmuSet.php')),
      'session=session-a',
    );
  });

  test(
    'an acknowledged write remains successful if navigation happens in flight',
    () async {
      final fixture = DanmakuSendFixture();
      addTearDown(fixture.sender.dispose);
      fixture.handler = (request) async {
        if (request.method == 'POST') fixture.live = false;
        return fixture.response(request);
      };
      expect((await fixture.send()).id, '91');
      expect(fixture.posts.length, 1);
    },
  );

  test('dispose during token request prevents sending', () async {
    final fixture = DanmakuSendFixture();
    final token = Completer<http.Response>();
    final waiting = Completer<void>();
    fixture.handler = (request) async {
      if (request.url.path.endsWith('getCSRFToken.php')) {
        waiting.complete();
        return token.future;
      }
      return fixture.response(request);
    };
    final sending = fixture.send();
    final rejected = expectLater(sending, throwsA(isA<CommunityException>()));
    await waiting.future;
    fixture.sender.dispose();
    token.complete(http.Response('offline-csrf', 200));
    await rejected;
    expect(fixture.posts, isEmpty);
  });
}
