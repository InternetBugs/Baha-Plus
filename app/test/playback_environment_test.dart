import 'dart:async';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/playback_environment.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.bahaplus.mobile/playback_environment');
  final updates = <Map<dynamic, dynamic>>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppStore store;
  late FakePortal portal;
  late PlaybackEnvironment environment;

  Future<void> flush() => Future<void>.delayed(Duration.zero);
  Map<dynamic, dynamic> getLast() => updates.last;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    updates.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      updates.add(call.arguments as Map);
      return null;
    });
    store = await AppStore.create(
      storage: MemoryStorage(),
      animeSearch: FakeSearch(),
    );
    portal = FakePortal();
    await store.attach(portal);
    await store.play(
      const Anime(
        id: '10',
        title: 'Test Anime',
        cover: 'https://p2.bahamut.com.tw/10.jpg',
        latestVideoId: '20',
      ),
    );
    store.playback.value = const PlaybackState(
      phase: PlaybackPhase.content,
      surfaceReady: true,
      duration: 1200,
      position: 637,
      paused: false,
    );
    environment = PlaybackEnvironment(store);
    await flush();
  });

  tearDown(() async {
    environment.dispose();
    await flush();
    store.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<dynamic> remote(
    String action, {
    String? document,
    dynamic value,
  }) async {
    final finished = Completer<dynamic>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('remoteCommand', {
          'action': action,
          'document': document ?? store.operation.id,
          'value': ?value,
        }),
      ),
      (reply) => finished.complete(channel.codec.decodeEnvelope(reply!)),
    );
    return finished.future;
  }

  test(
    'foreground playback stays awake and exports the actual media clock',
    () {
      expect(getLast()['keepAwake'], isTrue);
      expect(getLast()['playing'], isTrue);
      expect(getLast()['position'], 637);
      expect(getLast()['duration'], 1200);
      expect(getLast()['title'], 'Test Anime');
    },
  );

  test(
    'iOS native system seeking uses the current clock and rejects invalid or stale input',
    () async {
      store.updateNativePlayback(store.operation.id, store.playback.value);
      await flush();
      expect(getLast()['native'], isTrue);
      portal.scripts.clear();
      expect(await remote('seek', value: 240.5), isTrue);
      expect(portal.scripts.last, contains('"seek",240.5'));
      final sent = portal.scripts.length;
      expect(await remote('seek', value: '240'), isFalse);
      expect(await remote('seek', value: double.infinity), isFalse);
      expect(
        await remote('seek', value: 240, document: 'old-document'),
        isFalse,
      );
      environment.setForeground(false);
      expect(await remote('seek', value: 300), isFalse);
      expect(portal.scripts.length, sent);
    },
  );

  test('background, pause, and exit release the screen wake request', () async {
    environment.setForeground(false);
    await store.setApplicationActive(false);
    await flush();
    expect(getLast()['keepAwake'], isFalse);
    expect(getLast()['playing'], isFalse);
    expect(getLast()['position'], 637);
    expect(await remote('play'), isFalse);
    environment.setForeground(true);
    await store.setApplicationActive(true);
    store.playback.value = const PlaybackState(
      phase: PlaybackPhase.content,
      surfaceReady: true,
      duration: 1200,
      position: 637,
      paused: true,
    );
    await flush();
    expect(getLast()['keepAwake'], isFalse);
    await store.closeBrowser();
    await flush();
    expect(getLast()['active'], isFalse);
    expect(getLast()['keepAwake'], isFalse);
  });

  test(
    'system controls reach the current player and reject stale commands',
    () async {
      portal.scripts.clear();
      expect(await remote('pause'), isTrue);
      expect(portal.scripts.last, contains('"pause"'));
      expect(await remote('play'), isTrue);
      expect(portal.scripts.last, contains('"play"'));
      expect(await remote('toggle'), isTrue);
      expect(portal.scripts.last, contains('"pause"'));
      store.playback.value = const PlaybackState(
        phase: PlaybackPhase.loading,
        surfaceReady: true,
      );
      expect(await remote('pause'), isTrue);
      expect(portal.scripts.last, contains('"pause"'));
      expect(await remote('play'), isFalse);
      final count = portal.scripts.length;
      expect(await remote('play', document: 'old-document'), isFalse);
      expect(await remote('seek'), isFalse);
      expect(portal.scripts.length, count);
    },
  );
}
