import 'fake_playback.dart';
import 'fake_metadata.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baha_plus/core/browser_request.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/playback_environment.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

class _MediaPortal extends FakePortal {
  late FakeHttpPlayback session;
  set release(Completer<void> value) => session.closeGate = value;
  Completer<void>? get release => session.closeGate;
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
      nativeHttpApiFactory: PendingNativeHttpApi.new,
      metadataApi: FakeMetadata(),
      accountApi: portal.accountApi,
      storage: MemoryStorage(),
      animeSearch: FakeSearch(),
    );
    addTearDown(store.dispose);
    store.catalog = Catalog.fromJson(
      jsonDecode(File('test/fixtures/catalog.json').readAsStringSync()) as Json,
    );
    await store.attach(portal);
    await playFixture(
      store,
      anime,
      onCommand: (action, value) =>
          portal.recordPlayerCommand(store.operation.id, action, value),
    );
    portal.session = store.nativeHttpPlayback! as FakeHttpPlayback;
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
    'exiting playback releases native media before iOS Now Playing',
    () async {
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      portal.release = Completer<void>();
      final closing = store.closeBrowser();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      expect(store.browserVisible, isFalse);
      expect(store.playback.value.paused, isTrue);
      expect(portal.session.closeGate!.isCompleted, isFalse);
      portal.release!.complete();
      await closing;
      expect(calls.single.method, 'releasePlayback');
      expect(store.operation.intent, BrowserIntent.idle);

      await playFixture(
        store,
        anime,
        episode: const Episode(id: '21', label: '2'),
      );
      expect(store.showsPlayer, isTrue);
      expect(store.playingVideoId, '21');
      expect(portal.visited, isEmpty);
      expect(calls, hasLength(1));
    },
  );

  test(
    'backgrounding keeps a resumable session without clearing Now Playing',
    () async {
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      await store.setApplicationActive(false);
      expect(portal.scripts.last, contains('"pause"'));
      expect(calls, isEmpty);
      await store.setApplicationActive(true);
      expect(portal.scripts.last, contains('"pause"'));
      expect(calls, isEmpty);
    },
  );

  test('a system pause preserves Now Playing and the loaded media', () async {
    final portal = _MediaPortal();
    final store = await playingStore(portal);
    final environment = PlaybackEnvironment(store);
    addTearDown(environment.dispose);
    const environmentChannel = MethodChannel(
      'app.bahaplus.mobile/playback_environment',
    );
    final receipt = Completer<dynamic>();
    final before = portal.scripts.length;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          environmentChannel.name,
          environmentChannel.codec.encodeMethodCall(
            MethodCall('remoteCommand', {
              'document': store.operation.id,
              'action': 'pause',
              'source': 'audio-interruption',
              'requestId': 1,
            }),
          ),
          (reply) =>
              receipt.complete(environmentChannel.codec.decodeEnvelope(reply!)),
        );
    final response = await receipt.future as Map;
    expect(response['accepted'], isTrue);
    expect(response['action'], 'pause');
    expect(response['reason'], 'dispatched');
    expect(portal.scripts.skip(before).single, contains('"pause"'));
    expect(calls, isEmpty);
    expect(store.browserVisible, isTrue);
    expect(store.showsPlayer, isTrue);
  });

  test('a delayed exit cannot clear the next playback session', () async {
    final portal = _MediaPortal();
    final store = await playingStore(portal);
    portal.release = Completer<void>();
    final closing = store.closeBrowser();
    await Future<void>.delayed(Duration.zero);
    await playFixture(
      store,
      anime,
      episode: const Episode(id: '21', label: '2'),
    );
    final next = store.operation.id;
    portal.release!.complete();
    await closing;
    expect(calls, isEmpty);
    expect(store.operation.id, next);
    expect(store.showsPlayer, isTrue);
    expect(portal.visited, isEmpty);
  });

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
      await playFixture(store, anime);
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
      await playFixture(
        store,
        anime,
        episode: const Episode(id: '21', label: '2'),
      );
      final next = store.operation.id;
      portal.release!.complete();
      await navigation;
      expect(calls, isEmpty);
      expect(store.operation.id, next);
      expect(portal.visited, isEmpty);
    },
  );

  test(
    'Android exits release native media without calling the iOS channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final portal = _MediaPortal();
      final store = await playingStore(portal);
      await store.closeBrowser();
      expect(portal.visited, isEmpty);
      expect(calls, isEmpty);
    },
  );
}
