import 'dart:async';
import 'dart:convert';
import 'package:baha_plus/data/native_http_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const adConfig =
    'function(x){var adlist = '
    '[["123","label","456","video"],["999","label","888","ima"]];}';
const masterPlaylist =
    '#EXTM3U\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=640x360\n360.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=1920x1080\n1080.m3u8\n';

class HttpFixture {
  HttpFixture({this.ads = true});
  final bool ads;
  final requests = <http.Request>[];
  bool parent = false;
  int? denial;
  int progressCount = 0;
  List<Object?> danmakuRows = [
    {
      'sn': 1,
      'time': 100,
      'text': '<span>Test &amp; native</span>',
      'position': 0,
      'size': 1,
      'color': '#FFFFFF',
    },
  ];
  Future<http.Response> Function(http.Request request)? handler;

  late final client = MockClient((request) async {
    requests.add(request);
    if (handler != null) return handler!(request);
    return response(request);
  });
  NativeHttpApi api() => NativeHttpApi(client: client);
  int count(String endpoint) => requests
      .where((request) => request.url.path.endsWith('/$endpoint'))
      .length;

  http.Response response(http.Request request) {
    Object body = '';
    final headers = <String, String>{
      'content-type': 'application/json; charset=utf-8',
    };
    switch (request.url.path) {
      case '/animeVideo.php':
        body = '<html>official video</html>';
      case '/ajax/getdeviceid.php':
        headers['set-cookie'] =
            'ANIME_SIGN=guest-sign; Domain=gamer.com.tw; Path=/; Secure, '
            'guest=1; Domain=.gamer.com.tw; Path=/; Secure';
        body = {'deviceid': 'device-before-source'};
      case '/anime/v1/video.php':
        body = {
          'data': {
            'video': {
              'title': 'Sample',
              'rating': 1,
              'duration': 1200,
              'requestParentPassword': parent,
              'breakpoint': {'breakPoint': 10},
            },
          },
        };
      case '/ajax/token.php':
        body = denial == null
            ? {'time': ads ? 0 : 1, 'r18': 1}
            : {
                'error': {'code': denial},
              };
      case '/JS/ad/animeVideo.js':
        body = adConfig;
      case '/ajax/videoCastcishu.php':
      case '/ajax/checklock.php':
      case '/ajax/unlock.php':
        body = '';
      case '/anime/v1/video_src.php':
        body = {
          'data': {
            'deviceid': 'device-after-source',
            'srcUseCases': [
              {
                'deviceType': 2,
                'src': {'playlist': 'unsupported'},
              },
              {
                'deviceType': 1,
                'src': {
                  'playlist':
                      'https://bahamut.akamaized.net/content/master.m3u8',
                },
              },
            ],
          },
        };
      case '/content/master.m3u8':
        body = masterPlaylist;
      case '/content/360.m3u8':
      case '/content/1080.m3u8':
        body = '#EXTM3U\n#EXTINF:1200,\nsegment.ts\n#EXT-X-ENDLIST\n';
      case '/ajax/elapse.php':
        progressCount++;
        body = {'state': 'ok', 'device': 'device-progress-$progressCount'};
      case '/anime/v1/danmu.php':
        body = {
          'data': {'danmu': danmakuRows, 'totalCount': danmakuRows.length},
        };
      default:
        throw StateError('Unexpected fixture endpoint: ${request.url.path}');
    }
    return http.Response(
      body is String ? body : jsonEncode(body),
      200,
      headers: headers,
    );
  }
}

void main() {
  for (final values in <(Object?, Object?, int)>[
    (3, 1, 3),
    (6, 1, 6),
    (null, 4, 4),
    (null, null, 0),
    (7, 1, 0),
    (2.5, 1, 0),
    ('unknown', 1, 0),
  ]) {
    test(
      'official policy rating ${values.$1} and metadata ${values.$2} stay explicit',
      () async {
        final fixture = HttpFixture(ads: false);
        fixture.handler = (request) async {
          if (request.url.path == '/ajax/token.php') {
            return http.Response(
              jsonEncode({'time': 1, if (values.$1 != null) 'r18': values.$1}),
              200,
            );
          }
          if (request.url.path == '/anime/v1/video.php') {
            return http.Response(
              jsonEncode({
                'data': {
                  'video': {
                    'title': 'Sample',
                    'duration': 24,
                    if (values.$2 != null) 'rating': values.$2,
                  },
                },
              }),
              200,
            );
          }
          return fixture.response(request);
        };
        final api = fixture.api();
        addTearDown(api.dispose);
        expect((await api.prepare('40190')).rating, values.$3);
      },
    );
  }

  test(
    'native login cookies authorize playback and progress, never media',
    () async {
      final fixture = HttpFixture(ads: false);
      final imported = <NativeHttpCookieJar>[];
      final api = NativeHttpApi(
        client: fixture.client,
        cookieLoader: () async {
          final jar = NativeHttpCookieJar();
          jar.receive(
            Uri.https('ani.gamer.com.tw', '/'),
            'account=mock-login; Domain=gamer.com.tw; Path=/; Secure; HttpOnly',
          );
          imported.add(jar);
          return jar;
        },
      );
      addTearDown(api.dispose);
      final prepared = await api.prepare('40190');
      expect(api.usesDeviceSession, isTrue);
      expect(prepared.position, 10);
      api.consent();
      final source = await api.source();
      expect(source.position, 10);
      await api.started();
      expect(await api.progress(120, 1200), isTrue);
      for (final request in fixture.requests) {
        if (request.url.host.endsWith('.gamer.com.tw')) {
          expect(request.headers['cookie'], contains('account=mock-login'));
        } else {
          expect(request.headers['cookie'], isNull);
        }
      }
      api.dispose();
      for (final jar in imported) {
        expect(jar.header(NativeHttpApi.cookieURLs.first), isEmpty);
      }
    },
  );

  test(
    'a changed native login stops the old playback session before writing',
    () async {
      final fixture = HttpFixture(ads: false);
      var owner = 'first-account';
      final api = NativeHttpApi(
        client: fixture.client,
        cookieLoader: () async => NativeHttpCookieJar()
          ..receive(
            Uri.https('ani.gamer.com.tw', '/'),
            'account=$owner; Domain=gamer.com.tw; Path=/; Secure',
          ),
      );
      addTearDown(api.dispose);
      await api.prepare('40190');
      api.consent();
      await api.source();
      owner = 'another-account';
      final before = fixture.requests.length;
      await expectLater(
        api.progress(120, 1200),
        throwsA(
          isA<NativeHttpException>().having(
            (error) => error.stage,
            'stage',
            'session-changed',
          ),
        ),
      );
      expect(fixture.requests.length, before);
    },
  );

  test(
    'unavailable native cookies fail explicitly instead of playing as guest',
    () async {
      final fixture = HttpFixture(ads: false);
      final api = NativeHttpApi(
        client: fixture.client,
        cookieLoader: () async => throw StateError('unavailable'),
      );
      addTearDown(api.dispose);
      await expectLater(
        api.prepare('40190'),
        throwsA(
          isA<NativeHttpException>().having(
            (error) => error.stage,
            'stage',
            'session-unavailable',
          ),
        ),
      );
      expect(fixture.requests, isEmpty);
    },
  );

  test('closing while importing cookies clears the late snapshot', () async {
    final fixture = HttpFixture(ads: false);
    final pending = Completer<NativeHttpCookieJar>();
    final api = NativeHttpApi(
      client: fixture.client,
      cookieLoader: () => pending.future,
    );
    final prepared = api.prepare('40190');
    final assertion = expectLater(
      prepared,
      throwsA(isA<NativeHttpException>()),
    );
    api.dispose();
    final jar = NativeHttpCookieJar()
      ..receive(
        Uri.https('ani.gamer.com.tw', '/'),
        'account=late-login; Domain=gamer.com.tw; Path=/; Secure',
      );
    pending.complete(jar);
    await assertion;
    expect(jar.header(NativeHttpApi.cookieURLs.first), isEmpty);
    expect(fixture.requests, isEmpty);
  });

  test('native danmaku uses the episode guest session after consent', () async {
    final fixture = HttpFixture(ads: false);
    final api = fixture.api();
    addTearDown(api.dispose);
    await expectLater(
      api.danmaku(),
      throwsA(
        isA<NativeHttpException>().having(
          (error) => error.stage,
          'stage',
          'danmaku-gated',
        ),
      ),
    );
    await api.prepare('40190');
    await expectLater(api.danmaku(), throwsA(isA<NativeHttpException>()));
    api.consent();
    final items = await api.danmaku();
    final request = fixture.requests.last;
    expect(request.method, 'GET');
    expect(request.url.host, 'api.gamer.com.tw');
    expect(request.url.path, '/anime/v1/danmu.php');
    expect(request.url.queryParameters, {'videoSn': '40190', 'geo': 'TW,HK'});
    expect(request.headers['cookie'], contains('ANIME_SIGN=guest-sign'));
    expect(items.single.time, 10);
    expect(items.single.text, 'Test & native');
    expect(items.single.size, 24);
    await expectLater(Future.sync(() => items.clear()), throwsUnsupportedError);
  });

  test('danmaku cannot load before the required ad finishes', () async {
    final fixture = HttpFixture();
    final api = fixture.api();
    addTearDown(api.dispose);
    await api.prepare('40190');
    api.consent();
    await expectLater(api.danmaku(), throwsA(isA<NativeHttpException>()));
    expect(fixture.count('danmu.php'), 0);
  });

  test('official danmaku converts units, HTML, positions and sizes', () {
    Map<String, dynamic> row(int id, int time, int position, int size) => {
      'sn': id,
      'time': time,
      'text': '<span>  彈幕&nbsp;&lt;文字&gt; &#x1f41f; </span>',
      'color': '#FF9496',
      'position': position,
      'size': size,
    };
    final items = NativeHttpApi.parseDanmaku({
      'data': {
        'danmu': [
          row(30, 123, 2, 2),
          row(10, 0, 0, 0),
          row(20, 123, 1, 1),
          row(20, 400, 0, 0),
          {...row(40, 200, 0, 0), 'color': 'red', 'size': 999, 'position': 999},
        ],
      },
    });
    expect(items.map((item) => item.id), ['10', '20', '30', '40']);
    expect(items.map((item) => item.time), [0, 12.3, 12.3, 20]);
    expect(items.map((item) => item.size), [16, 24, 28, 24]);
    expect(items.map((item) => item.mode), [
      'rolling',
      'top',
      'bottom',
      'rolling',
    ]);
    expect(items.first.text, '彈幕 <文字> 🐟');
    expect(items.first.color.toARGB32(), 0xffff9496);
    expect(items.last.color.toARGB32(), 0xffffffff);
  });

  test('malformed rows cannot poison valid danmaku or expose markup', () {
    final valid = {
      'sn': '7',
      'time': 5,
      'position': 0,
      'size': 1,
      'text': '<img src="https://invalid/" onerror="alert(1)"> safe',
      'color': '#FFFFFF',
    };
    final items = NativeHttpApi.parseDanmaku({
      'data': {
        'danmu': [
          null,
          5,
          {},
          {...valid, 'sn': 'bad'},
          {...valid, 'time': -1},
          {...valid, 'time': double.infinity},
          {...valid, 'time': 1728001},
          {...valid, 'text': 'x' * 501},
          {...valid, 'text': '<b> </b>'},
          {...valid, 'text': 4},
          valid,
        ],
      },
    });
    expect(items.single.text, 'safe');
    expect(items.single.time, .5);
    for (final body in <Map<String, dynamic>>[
      {},
      {'data': []},
      {
        'data': {'danmu': {}},
      },
      {
        'data': {'danmu': List.filled(20001, valid)},
      },
    ]) {
      expect(
        () => NativeHttpApi.parseDanmaku(body),
        throwsA(isA<NativeHttpException>()),
      );
    }
    expect(
      NativeHttpApi.parseDanmaku({
        'data': {'danmu': []},
      }),
      isEmpty,
    );
  });

  test('guest cookies handle parent domains, host-only paths and expiry', () {
    final jar = NativeHttpCookieJar();
    final page = Uri.parse('https://ani.gamer.com.tw/ajax/device.php');
    final api = Uri.parse('https://api.gamer.com.tw/anime/v1/video.php');
    final now = DateTime.utc(2026, 11, 13);
    jar.receive(
      page,
      'ANIME_SIGN=abc; Domain=gamer.com.tw; Path=/; Secure, '
      'second=def; Domain=.gamer.com.tw; Path=/; Secure, '
      'host=one; Path=/ajax; Secure',
      now: now,
    );
    expect(jar.header(api, now: now), 'ANIME_SIGN=abc; second=def');
    expect(jar.header(page, now: now), startsWith('host=one; '));
    expect(
      jar.header(page.replace(path: '/ajax2/a'), now: now),
      'ANIME_SIGN=abc; second=def',
    );
    jar.receive(
      page,
      'ANIME_SIGN=new; Domain=gamer.com.tw; Path=/; Max-Age=1',
      now: now,
    );
    expect(jar.header(api, now: now), contains('ANIME_SIGN=new'));
    expect(
      jar.header(api, now: now.add(const Duration(seconds: 2))),
      'second=def',
    );
    jar.receive(
      page,
      'second=x; Domain=gamer.com.tw; Path=/; Max-Age=0',
      now: now,
    );
    expect(jar.header(api, now: now), isEmpty);
  });

  test('cookies never leave the two fixed HTTPS origins', () {
    final jar = NativeHttpCookieJar();
    final page = Uri.parse('https://ani.gamer.com.tw/');
    jar.receive(page, 'sign=ok; Domain=gamer.com.tw; Path=/');
    jar.receive(page, 'evil=no; Domain=com.tw; Path=/');
    jar.receive(page, 'evil2=no; Domain=api.gamer.com.tw; Path=/');
    for (final uri in [
      'http://ani.gamer.com.tw/',
      'https://ani.gamer.com.tw:444/',
      'https://i2.bahamut.com.tw/',
      'https://bahamut.akamaized.net/',
      'https://evil.gamer.com.tw/',
      'https://user@ani.gamer.com.tw/',
    ]) {
      expect(jar.header(Uri.parse(uri)), isEmpty);
    }
    expect(jar.header(page), 'sign=ok');
  });

  test('Expires commas and cookie replacement preserve browser format', () {
    final jar = NativeHttpCookieJar();
    final page = Uri.parse('https://ani.gamer.com.tw/');
    final now = DateTime.utc(2026, 11, 13);
    jar.receive(
      page,
      'a=1; Expires=Sun, 15 Nov 2026 00:00:00 GMT; Path=/, b=2; Path=/',
      now: now,
    );
    expect(jar.header(page, now: now), 'a=1; b=2');
    jar.receive(page, 'a=3; Path=/', now: now);
    expect(jar.header(page, now: now), 'b=2; a=3');
  });

  test(
    'authorization cannot skip consent, real ad time or acknowledged END',
    () async {
      final fixture = HttpFixture();
      final api = fixture.api();
      addTearDown(api.dispose);
      final prepared = await api.prepare('40190');
      expect(prepared.ad!.id, '123');
      expect(fixture.count('video_src.php'), 0);
      await expectLater(api.source(), throwsA(isA<NativeHttpException>()));
      await expectLater(api.startAd(), throwsA(isA<NativeHttpException>()));
      api.consent();
      await expectLater(api.source(), throwsA(isA<NativeHttpException>()));
      await api.startAd();
      for (final seconds in [0.0, 29.999, double.nan, double.infinity]) {
        await expectLater(
          api.endAd(seconds),
          throwsA(isA<NativeHttpException>()),
        );
      }
      expect(fixture.count('video_src.php'), 0);
      await api.endAd(30);
      final source = await api.source();
      expect(source.position, 10);
      expect(source.variants.keys, [360, 1080]);
      expect(source.variants[360]!.path, '/content/360.m3u8');
      expect(fixture.count('videoCastcishu.php'), 2);
      final policy = fixture.requests.firstWhere(
        (request) => request.url.path == '/ajax/token.php',
      );
      expect(policy.headers['cookie'], 'ANIME_SIGN=guest-sign; guest=1');
      final media = fixture.requests.last;
      expect(media.headers.containsKey('cookie'), isFalse);
    },
  );

  test('resume bounds use HLS seconds rather than catalog duration', () async {
    final fixture = HttpFixture(ads: false);
    fixture.handler = (request) async {
      if (request.url.path == '/anime/v1/video.php') {
        return http.Response(
          jsonEncode({
            'data': {
              'video': {'title': 'Sample', 'duration': 10},
            },
          }),
          200,
        );
      }
      return fixture.response(request);
    };
    final api = fixture.api();
    addTearDown(api.dispose);
    await api.prepare('40190');
    api.consent();
    final source = await api.source(position: 77);
    expect(source.duration, 1200);
    expect(source.position, 77);
  });

  test(
    'notification return codes are distinct from structured policy errors',
    () async {
      final fixture = HttpFixture(ads: false);
      final api = fixture.api();
      addTearDown(api.dispose);
      await api.prepare('40190');
      api.consent();
      await api.source();
      for (final marker in [0, false, 2]) {
        fixture.handler = (request) async =>
            http.Response(jsonEncode({'error': marker}), 200);
        await api.started();
        await api.state(61);
      }
      fixture.handler = (_) async => http.Response('{"error":{"code":9}}', 200);
      await expectLater(api.started(), throwsA(isA<NativeHttpException>()));
    },
  );

  test('ad-free official policy still requires explicit consent', () async {
    final fixture = HttpFixture(ads: false);
    final api = fixture.api();
    addTearDown(api.dispose);
    expect((await api.prepare('40190')).ad, isNull);
    await expectLater(api.source(), throwsA(isA<NativeHttpException>()));
    api.consent();
    await api.source();
    expect(fixture.count('animeVideo.js'), 0);
    expect(fixture.count('videoCastcishu.php'), 0);
  });

  test(
    'source and progress device rotations feed subsequent requests',
    () async {
      final fixture = HttpFixture(ads: false);
      final api = fixture.api();
      addTearDown(api.dispose);
      await api.prepare('40190');
      api.consent();
      await api.source();
      await api.started();
      expect(
        fixture.requests
            .firstWhere((request) => request.url.path == '/ajax/checklock.php')
            .url
            .queryParameters['device'],
        'device-after-source',
      );
      expect(await api.progress(42, 1200), isTrue);
      expect(await api.progress(65, 1200), isTrue);
      final progress = fixture.requests
          .where((request) => request.url.path == '/ajax/elapse.php')
          .toList();
      expect(progress[0].url.queryParameters['device'], 'device-after-source');
      expect(progress[1].url.queryParameters['device'], 'device-progress-1');
    },
  );

  test('parent verification and policy denials never request media', () async {
    for (final parent in [true, false]) {
      final fixture = HttpFixture()..parent = parent;
      if (!parent) fixture.denial = 1007;
      final api = fixture.api();
      try {
        await expectLater(
          api.prepare('40190'),
          throwsA(
            isA<NativeHttpException>().having(
              (error) => error.stage,
              'stage',
              parent ? 'parent-verification-required' : 'policy',
            ),
          ),
        );
        expect(fixture.count('video_src.php'), 0);
        expect(fixture.count('animeVideo.js'), 0);
      } finally {
        api.dispose();
      }
    }
  });

  test('failed ad acknowledgement cannot open source gate', () async {
    final fixture = HttpFixture();
    final api = fixture.api();
    addTearDown(api.dispose);
    await api.prepare('40190');
    api.consent();
    await api.startAd();
    fixture.handler = (request) async =>
        request.url.queryParameters['ad'] == 'end'
        ? http.Response('{"error":{"code":9}}', 200)
        : fixture.response(request);
    await expectLater(api.endAd(31), throwsA(isA<NativeHttpException>()));
    await expectLater(api.source(), throwsA(isA<NativeHttpException>()));
    expect(fixture.count('video_src.php'), 0);
  });

  test('malformed ads and playlists fail without executing JavaScript', () {
    for (final config in ['alert("x")', 'function(){var adlist = [];}']) {
      expect(() => NativeHttpApi.parseAds(config), throwsA(anything));
    }
    final master = Uri.parse('https://bahamut.akamaized.net/master.m3u8');
    expect(
      () => NativeHttpApi.parseVariants(master, '<html>no</html>'),
      throwsA(isA<NativeHttpException>()),
    );
    for (final uri in [
      'https://evil.test/master.m3u8',
      'http://bahamut.akamaized.net/master.m3u8',
      'https://user@bahamut.akamaized.net/master.m3u8',
    ]) {
      expect(
        () => NativeHttpApi.parseVariants(
          master,
          '#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=640x360\n$uri\n',
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test(
    'progress preserves official completion semantics and guest distinction',
    () async {
      expect(NativeHttpApi.progressParameter(42.5, 1200), 43);
      expect(NativeHttpApi.progressParameter(1080, 1200), -1);
      expect(
        () => NativeHttpApi.progressParameter(double.nan, 1200),
        throwsA(isA<NativeHttpException>()),
      );
      final fixture = HttpFixture(ads: false);
      final api = fixture.api();
      addTearDown(api.dispose);
      await api.prepare('40190');
      api.consent();
      await api.source();
      fixture.handler = (_) async => http.Response('{"state":1}', 200);
      expect(await api.progress(42, 1200), isFalse);
      fixture.handler = (_) async => http.Response('{"state":2}', 200);
      await expectLater(
        api.progress(42, 1200),
        throwsA(
          isA<NativeHttpException>().having(
            (error) => error.stage,
            'stage',
            'progress-denied',
          ),
        ),
      );
    },
  );

  test(
    'redirects, challenges, oversized responses and timeouts fail safely',
    () async {
      for (final response in [
        http.Response(
          'session-secret',
          302,
          headers: {'location': 'https://evil.test'},
        ),
        http.Response('<html>cf-chl-secret</html>', 200),
        http.Response('x' * 2000001, 200),
      ]) {
        final api = NativeHttpApi(client: MockClient((_) async => response));
        try {
          await expectLater(
            api.prepare('40190'),
            throwsA(
              isA<NativeHttpException>().having(
                (error) => '$error',
                'sanitized',
                isNot(contains('session-secret')),
              ),
            ),
          );
        } finally {
          api.dispose();
        }
      }
      final pending = Completer<http.Response>();
      final api = NativeHttpApi(
        client: MockClient((_) => pending.future),
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        api.prepare('40190'),
        throwsA(
          isA<NativeHttpException>().having(
            (error) => error.stage,
            'stage',
            'page-timeout',
          ),
        ),
      );
      api.dispose();
      pending.complete(http.Response('', 200));
    },
  );

  test('unchanged native samples and completion do not lose real ad time', () {
    final watch = NativeHttpWatchClock();
    void sample(
      int ms,
      double position, {
      bool playing = true,
      bool ended = false,
    }) => watch.sample(
      position: position,
      now: Duration(milliseconds: ms),
      playing: playing,
      completed: ended,
    );
    sample(0, 0);
    sample(50, 0);
    sample(100, .1);
    expect(watch.total, .1);
    sample(150, .1);
    sample(200, .2);
    expect(watch.total, .2);
    sample(210, .2, playing: false); // plugin pauses before its final clock
    sample(215, .25, playing: false);
    expect(watch.total, closeTo(.25, 1e-9));
    sample(220, .3, playing: false, ended: true);
    expect(watch.total, closeTo(.3, 1e-9));
    sample(230, .3, playing: false, ended: true);
    expect(watch.total, closeTo(.3, 1e-9));
    watch.discontinuity();
    sample(240, 10, playing: false, ended: true);
    expect(watch.total, closeTo(.3, 1e-9));
  });

  test('watch clock excludes seeks, buffering, pauses and long stalls', () {
    final watch = NativeHttpWatchClock();
    void sample(
      int ms,
      double position, {
      bool playing = true,
      double rate = 1,
    }) => watch.sample(
      position: position,
      now: Duration(milliseconds: ms),
      playing: playing,
      rate: rate,
    );
    sample(0, 0);
    sample(1000, 1);
    sample(2000, 11); // seek distance
    sample(3000, 12);
    expect(watch.total, 2);
    sample(4000, 12, playing: false);
    sample(5000, 12);
    sample(6000, 13);
    sample(10000, 17); // stale sampling gap
    expect(watch.total, 3);
    watch.discontinuity();
    sample(11000, 42);
    sample(12000, 43.5, rate: 1.5);
    expect(watch.total, 4.5);
  });

  test(
    'unseekable ad clock retains actual progress across delayed samples',
    () {
      final watch = NativeHttpWatchClock();
      for (final position in [0.0, .1, .1, .1, 10.0, 10.0, 9.9, 29.949]) {
        watch.sampleUnseekable(position);
      }
      expect(watch.total, 29.949);
      watch.sampleUnseekable(30.03);
      watch.sampleUnseekable(30.03);
      expect(watch.total, 30.03);
      watch.sampleUnseekable(double.nan);
      expect(watch.total, 30.03);
    },
  );
}
