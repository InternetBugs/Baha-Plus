import 'dart:async';

import 'package:baha_plus/data/ios_hls_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.bahaplus.mobile/hls_cache');
  const document = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const next = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const source = 'https://bahamut.akamaized.net/show/master.m3u8?token=fixture';
  const base = 'http://localhost:12345/01234567-89ab-cdef-0123-456789abcdef/';
  final calls = <MethodCall>[];

  Map<String, String> endpoint({String origin = base}) => {
    'base': origin,
    'url': '${origin}media.m3u8?u=${Uri.encodeComponent(source)}',
  };

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'prepare' ? endpoint() : null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'a validated cache gateway retains the exact authorized source',
    () async {
      final cache = IOSHlsCache();
      final result = await cache.prepare(
        document: document,
        videoId: '20',
        source: source,
      );
      expect(result!.base, base);
      expect(Uri.parse(result.url).queryParameters['u'], source);
      expect(calls.single.arguments, {
        'document': document,
        'videoId': '20',
        'source': source,
      });
      await cache.update(document, 37);
      await cache.update(document, 38);
      await cache.update(document, 43);
      expect(calls.where((call) => call.method == 'update'), hasLength(2));
      await cache.stop(document);
      await cache.update(document, 60);
      expect(cache.document, isNull);
      expect(calls.last.method, 'stop');
    },
  );

  test(
    'untrusted sources and invalid sessions never reach native transport',
    () async {
      final cache = IOSHlsCache();
      for (final url in [
        'http://bahamut.akamaized.net/a.m3u8',
        'https://attacker.test/a.m3u8',
        'https://user:pass@bahamut.akamaized.net/a.m3u8',
        'https://bahamut.akamaized.net:444/a.m3u8',
        'https://bahamut.akamaized.net/a.mp4',
        'https://bahamut.akamaized.net/a.m3u8#fragment',
      ]) {
        expect(
          await cache.prepare(document: document, videoId: '20', source: url),
          isNull,
        );
      }
      expect(
        await cache.prepare(document: 'invalid', videoId: '20', source: source),
        isNull,
      );
      expect(
        await cache.prepare(
          document: document,
          videoId: '../20',
          source: source,
        ),
        isNull,
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'foreign or malformed native endpoints are rejected and stopped',
    () async {
      for (final origin in [
        'http://192.168.0.1:12345/01234567-89ab-cdef-0123-456789abcdef/',
        'http://localhost:80/01234567-89ab-cdef-0123-456789abcdef/',
        'https://localhost:12345/01234567-89ab-cdef-0123-456789abcdef/',
        'http://localhost:12345/invalid/',
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return call.method == 'prepare' ? endpoint(origin: origin) : null;
            });
        expect(
          await IOSHlsCache().prepare(
            document: document,
            videoId: '20',
            source: source,
          ),
          isNull,
        );
        expect(calls.last.method, 'stop');
      }
    },
  );

  test(
    'a late native prepare cannot replace a newer episode session',
    () async {
      final pending = Completer<Map<String, String>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'prepare' &&
                (call.arguments as Map)['document'] == document) {
              return pending.future;
            }
            return call.method == 'prepare' ? endpoint() : null;
          });
      final cache = IOSHlsCache();
      final old = cache.prepare(
        document: document,
        videoId: '20',
        source: source,
      );
      await Future<void>.delayed(Duration.zero);
      final current = await cache.prepare(
        document: next,
        videoId: '21',
        source: source,
      );
      pending.complete(endpoint());
      expect(await old, isNull);
      expect(current, isNotNull);
      await cache.stop(document);
      expect(cache.document, next);
    },
  );

  test(
    'unavailable native transport retains normal official playback',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => throw PlatformException(code: 'unavailable'),
          );
      final cache = IOSHlsCache();
      expect(
        await cache.prepare(document: document, videoId: '20', source: source),
        isNull,
      );
      await cache.stop(document);
    },
  );
}
