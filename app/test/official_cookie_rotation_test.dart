import 'dart:async';
import 'dart:io' as io;

import 'package:baha_plus/data/native_http_api.dart';
import 'package:baha_plus/data/official_cookie_rotation.dart';
import 'package:baha_plus/data/official_http_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Manager extends Fake implements CookieManager {
  final cookies = [
    Cookie(name: 'BAHAID', value: 'alice'),
    Cookie(name: 'BAHARUNE', value: 'old'),
  ];
  final writes = <Map<Symbol, dynamic>>[];
  Future<void> Function()? onRead;
  Future<void> Function()? onWrite;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getCookies) {
      return () async {
        await onRead?.call();
        return cookies;
      }();
    }
    if (invocation.memberName == #setCookie) {
      return () async {
        final args = invocation.namedArguments;
        writes.add(args);
        await onWrite?.call();
        cookies.removeWhere((item) => item.name == 'BAHARUNE');
        cookies.add(Cookie(name: 'BAHARUNE', value: args[#value]));
        return true;
      }();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  late _Manager manager;
  final endpoint = Uri.https('ani.gamer.com.tw', '/ajax/session');
  Future<bool> persist({
    String raw = 'BAHARUNE=new',
    String sent = 'BAHAID=alice; BAHARUNE=old',
    bool hostOnly = true,
    Uri? uri,
    bool Function()? current,
  }) => OfficialCookieRotation.persist(
    uri ?? endpoint,
    io.Cookie.fromSetCookieValue(raw),
    hostOnly,
    sent,
    current ?? () => true,
  );

  setUp(() {
    OfficialCookieRotation.invalidate();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    manager = _Manager();
    OfficialCookieRotation.managerOverride = manager;
  });
  tearDown(() {
    OfficialCookieRotation.managerOverride = null;
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test('$platform preserves host-only and explicit domain attributes', () async {
      debugDefaultTargetPlatformOverride = platform;
      expect(await persist(), isTrue);
      expect(manager.writes.single[#domain], isNull);
      expect(manager.writes.single[#path], '/ajax');
      expect(manager.writes.single[#expiresDate], isNull);
      expect(await persist(
        raw: 'BAHARUNE=last; Domain=gamer.com.tw; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=600',
        hostOnly: false,
        sent: 'BAHAID=alice; BAHARUNE=new',
      ), isTrue);
      final write = manager.writes.last;
      expect(write[#domain], '.gamer.com.tw');
      expect(write[#path], '/');
      expect(write[#isSecure], isTrue);
      expect(write[#isHttpOnly], isTrue);
      expect(write[#sameSite], same(HTTPCookieSameSitePolicy.STRICT));
      expect(write[#expiresDate], greaterThan(DateTime.now().millisecondsSinceEpoch));
    });
  }

  test('expired empty cookie deletes the exact stored scope', () async {
    expect(await persist(raw: 'BAHARUNE=; Path=/ajax; Max-Age=0'), isTrue);
    expect(manager.writes.single[#domain], isNull);
    expect(manager.writes.single[#path], '/ajax');
    expect(manager.writes.single[#expiresDate], lessThan(DateTime.now().millisecondsSinceEpoch));
  });

  test('requires a trusted origin and unique matching request and store identities', () async {
    for (final uri in [
      Uri.parse('http://ani.gamer.com.tw'),
      Uri.parse('https://api.gamer.com.tw:444'),
      Uri.parse('https://home.gamer.com.tw'),
    ]) {
      expect(await persist(uri: uri), isFalse);
    }
    for (final sent in [
      'BAHARUNE=old',
      'BAHAID=alice; BAHARUNE=',
      'BAHAID=alice; BAHAID=alice; BAHARUNE=old',
      'BAHAID=bob; BAHARUNE=old',
      'BAHAID=alice; BAHARUNE=earlier',
    ]) {
      expect(await persist(sent: sent), isFalse);
    }
    expect(await persist(raw: 'BAHAID=other'), isFalse);
    expect(await persist(raw: 'BAHARUNE=new; Domain=com.tw', hostOnly: false), isFalse);
    manager.cookies.add(Cookie(name: 'BAHARUNE', value: 'old'));
    expect(await persist(), isFalse);
    expect(manager.writes, isEmpty);
  });

  test('WebView2 imports session and live cookies with expiry in seconds', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    manager.cookies
      ..clear()
      ..addAll([
        Cookie(name: 'BAHAID', value: 'alice', expiresDate: -1, isSessionOnly: true),
        Cookie(name: 'BAHARUNE', value: 'live', expiresDate: seconds + 600),
        Cookie(name: 'expired', value: 'old', expiresDate: seconds - 60),
      ]);
    final jar = await OfficialHttpClient.loadCookies(urls: [endpoint]);
    expect(jar.header(endpoint).split('; '), unorderedEquals(['BAHAID=alice', 'BAHARUNE=live']));
  });

  test('renewal survives a new session and an overlapping playback snapshot', () async {
    final uri = Uri.https('api.gamer.com.tw', '/anime/v3/history.php');
    Future<NativeHttpCookieJar> load() => OfficialHttpClient.loadCookies(urls: [uri]);

    final playback = await load();
    final initial = playback.fingerprint([uri]);
    final requests = <String?>[];
    final client = OfficialHttpClient(
      cookieLoader: load,
      client: MockClient((request) async {
        requests.add(request.headers['cookie']);
        return http.Response('ok', 200, headers: {
          if (requests.length == 1)
            'set-cookie': 'operation=one; Path=/, BAHARUNE=new; Domain=.gamer.com.tw; Path=/; Secure; HttpOnly',
        });
      }),
    );
    addTearDown(client.dispose);
    await client.session((session) async {
      await session.get(uri);
      await session.revalidate();
      await session.get(uri);
    });
    await client.session((session) => session.get(uri));
    expect(requests[0], contains('BAHARUNE=old'));
    expect(requests[1], allOf(contains('BAHARUNE=new'), contains('operation=one')));
    expect(requests[2], allOf(contains('BAHARUNE=new'), isNot(contains('operation=one'))));
    final device = await load();
    expect(device.fingerprint([uri]), initial);
    playback.adoptDeviceRotation(device);
    expect(playback.header(uri), contains('BAHARUNE=new'));
  });

  test('only the latest native rotation maps to the original token', () async {
    expect(await persist(), isTrue);
    expect(await persist(raw: 'BAHARUNE=last', sent: 'BAHAID=alice; BAHARUNE=new'), isTrue);
    expect(OfficialCookieRotation.fingerprintValue('last'), 'old');
    expect(OfficialCookieRotation.fingerprintValue('new'), 'new');
    expect(OfficialCookieRotation.isLatest('last'), isTrue);
    expect(await persist(raw: 'BAHARUNE=; Max-Age=0', sent: 'BAHAID=alice; BAHARUNE=last'), isTrue);
    expect(OfficialCookieRotation.fingerprintValue('last'), 'last');
    expect(OfficialCookieRotation.isLatest('last'), isFalse);
  });

  test('simultaneous responses compete against the latest stored token', () async {
    final results = await Future.wait([persist(), persist(raw: 'BAHARUNE=later')]);
    expect(results, [true, false]);
    expect(manager.writes, hasLength(1));
  });

  test('clear invalidates a pending read and waits for an active write', () async {
    final reading = Completer<void>(), resumeRead = Completer<void>();
    manager.onRead = () {
      reading.complete();
      return resumeRead.future;
    };
    final first = persist();
    await reading.future;
    final clear = OfficialCookieRotation.clear(() async {});
    resumeRead.complete();
    expect(await first, isFalse);
    await clear;
    manager.onRead = null;
    final writing = Completer<void>(), resumeWrite = Completer<void>();
    manager.onWrite = () {
      writing.complete();
      return resumeWrite.future;
    };
    final second = persist();
    await writing.future;
    var cleared = false;
    final clearing = OfficialCookieRotation.clear(() async {
      cleared = true;
      manager.cookies.clear();
    });
    expect(cleared, isFalse);
    resumeWrite.complete();
    await second;
    await clearing;
    expect(manager.cookies, isEmpty);
    expect(OfficialCookieRotation.isLatest('new'), isFalse);
  });

  test('rechecks the caller after store reads and recovers from platform errors', () async {
    var current = true;
    manager.onRead = () async { current = false; };
    expect(await persist(current: () => current), isFalse);
    manager.onRead = () async { throw StateError('unavailable'); };
    expect(await persist(), isFalse);
    expect(manager.writes, isEmpty);
    manager.onRead = null;
    expect(await persist(), isTrue);
  });
}
