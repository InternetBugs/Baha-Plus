import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baha_plus/core/browser_request.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

class _MediaPortal extends FakePortal {
  Completer<void>? release;
  bool failRelease = false;

  @override
  Future<dynamic> evaluate(String script) async {
    final result = await super.evaluate(script);
    if (script.contains('session.metadata = null')) {
      await release?.future;
      if (failRelease) throw StateError('Document destroyed');
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.bahaplus.mobile/media_session');
  const anime = Anime(
    id: '10',
    title: 'Test Anime',
    cover: 'https://p2.bahamut.com.tw/10.jpg',
    latestVideoId: '20',
  );
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<AppStore> playingStore(_MediaPortal portal) async {
    final store = await AppStore.create(
      storage: MemoryStorage(),
      animeSearch: FakeSearch(),
    );
    addTearDown(store.dispose);
    store.catalog = Catalog.fromJson(
      jsonDecode(File('test/fixtures/catalog.json').readAsStringSync()) as Json,
    );
    await store.attach(portal);
    await store.play(anime);
    // Focus these tests on teardown rather than delayed account sync.
    store.accountNeedsRefresh = false;
    store.updateNavigation(OfficialSite.video('20'), canGoBack: false);
    store.playback.value = const PlaybackState(
      phase: PlaybackPhase.content,
      surfaceReady: true,
      paused: false,
    );
    return store;
  }

  test(
    'exiting playback unloads web media before releasing iOS Now Playing',
    () async {
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      final document = store.operation.id;
      portal.release = Completer<void>();
      final closing = store.closeBrowser();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      expect(store.browserVisible, isFalse);
      expect(store.playback.value.paused, isTrue);
      expect(portal.scripts.last, contains(document));
      expect(portal.scripts.last, contains('media.removeAttribute(\'src\')'));
      expect(portal.scripts.last, contains('media.load()'));
      portal.release!.complete();
      await closing;
      expect(calls.single.method, 'releasePlayback');
      expect(store.operation.intent, BrowserIntent.idle);

      await store.play(
        anime,
        episode: const Episode(id: '21', label: '2'),
      );
      expect(store.showsPlayer, isTrue);
      expect(store.playingVideoId, '21');
      expect(portal.visited.last, OfficialSite.video('21'));
      expect(calls, hasLength(1));
    },
  );

  test(
    'backgrounding keeps a resumable session without clearing Now Playing',
    () async {
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      await store.setApplicationActive(false);
      expect(portal.scripts.last, contains('media.pause()'));
      expect(portal.scripts.last, isNot(contains('media.load()')));
      expect(calls, isEmpty);
      await store.setApplicationActive(true);
      expect(portal.scripts.last, contains('__bahaMediaSuspended = false'));
      expect(portal.scripts.last, isNot(contains('.play(')));
      expect(calls, isEmpty);
    },
  );

  test('a delayed exit cannot clear the next playback session', () async {
    final portal = _MediaPortal();
    final store = await playingStore(portal);
    portal.release = Completer<void>();
    final closing = store.closeBrowser();
    await Future<void>.delayed(Duration.zero);
    await store.play(
      anime,
      episode: const Episode(id: '21', label: '2'),
    );
    final next = store.operation.id;
    portal.release!.complete();
    await closing;
    expect(calls, isEmpty);
    expect(store.operation.id, next);
    expect(store.showsPlayer, isTrue);
    expect(portal.visited.last, OfficialSite.video('21'));
  });

  test(
    'a destroyed web document still releases the iOS system session',
    () async {
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      portal.failRelease = true;
      await store.closeBrowser();
      expect(calls.single.method, 'releasePlayback');
      expect(store.browserVisible, isFalse);
    },
  );

  test(
    'a hidden player document finishing after exit is also released',
    () async {
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      await store.closeBrowser();
      calls.clear();
      final before = portal.scripts.length;
      await store.navigationFinished(OfficialSite.video('20'));
      expect(portal.scripts[before], contains('session.metadata = null'));
      expect(calls.single.method, 'releasePlayback');
      expect(store.showsPlayer, isFalse);
    },
  );

  test(
    'a late hidden player is released while account sync is already active',
    () async {
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      await store.closeBrowser();
      await store.syncAccount();
      expect(store.operation.intent, BrowserIntent.accountRefresh);
      calls.clear();
      final before = portal.scripts.length;
      await store.navigationFinished(OfficialSite.video('20'));
      expect(portal.scripts[before], contains('session.metadata = null'));
      expect(calls.single.method, 'releasePlayback');
      expect(store.showsPlayer, isFalse);
    },
  );

  test(
    'an iOS audio session failure does not prevent exiting or reopening',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'audio_session_release_failed');
          });
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      await store.closeBrowser();
      expect(store.browserVisible, isFalse);
      await store.play(anime);
      expect(store.showsPlayer, isTrue);
    },
  );

  test('navigating away from playback releases its system session', () async {
    final portal = _MediaPortal();
    final store = await playingStore(portal);
    await store.connectAccount();
    expect(calls.single.method, 'releasePlayback');
    expect(portal.visited.last, OfficialSite.home.resolve('mygather.php'));
    expect(store.showsPlayer, isFalse);
  });

  test(
    'a delayed navigation cannot replace a newer playback request',
    () async {
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      portal.release = Completer<void>();
      final navigation = store.connectAccount();
      await Future<void>.delayed(Duration.zero);
      await store.play(
        anime,
        episode: const Episode(id: '21', label: '2'),
      );
      final next = store.operation.id;
      portal.release!.complete();
      await navigation;
      expect(calls, isEmpty);
      expect(store.operation.id, next);
      expect(portal.visited.last, OfficialSite.video('21'));
    },
  );

  test('Android exits unload media without calling the iOS channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final portal = _MediaPortal();
    final store = await playingStore(portal);
    await store.closeBrowser();
    expect(portal.scripts.last, contains('session.metadata = null'));
    expect(calls, isEmpty);
  });
}
