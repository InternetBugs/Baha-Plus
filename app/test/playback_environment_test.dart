import 'fake_metadata.dart';
import 'dart:async';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/playback_environment.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

class _PlaybackPortal extends FakePortal {
  Future<bool> Function(String, String, double?)? onPlayerCommand;

  @override
  Future<bool> playerCommand(
    String document,
    String action,
    double? value,
  ) async {
    if (onPlayerCommand != null) {
      return onPlayerCommand!(document, action, value);
    }
    return super.playerCommand(document, action, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.bahaplus.mobile/playback_environment');
  final updates = <Map<dynamic, dynamic>>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppStore store;
  late _PlaybackPortal portal;
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
      metadataApi: FakeMetadata(),
      storage: MemoryStorage(),
      animeSearch: FakeSearch(),
    );
    portal = _PlaybackPortal();
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
    int? requestId,
    String? source,
  }) async {
    final finished = Completer<dynamic>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('remoteCommand', {
          'action': action,
          'document': document ?? store.operation.id,
          'value': ?value,
          'requestId': ?requestId,
          'source': ?source,
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
      expect(await remote('seek', value: -1), isFalse);
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

  test(
    'native pause receipt waits for dispatch and reports the observed state',
    () async {
      final finished = Completer<bool>();
      store.updateNativePlayback(store.operation.id, store.playback.value);
      portal.onPlayerCommand = (document, action, value) {
        expect(document, store.operation.id);
        expect(action, 'pause');
        expect(value, isNull);
        return finished.future;
      };
      var replied = false;
      final pending = remote('pause', requestId: 41, source: 'remote-command')
          .then((value) {
            replied = true;
            return value;
          });
      await flush();
      expect(replied, isFalse);
      store.updateNativePlayback(
        store.operation.id,
        const PlaybackState(
          phase: PlaybackPhase.content,
          surfaceReady: true,
          duration: 1200,
          position: 637,
          paused: true,
        ),
      );
      finished.complete(true);
      expect(await pending, {
        'requestId': 41,
        'accepted': true,
        'reason': 'dispatched',
        'action': 'pause',
        'stateMatches': true,
        'paused': true,
        'position': 637,
      });
    },
  );

  test('a backend rejection cannot be reported as an observed pause', () async {
    portal.onPlayerCommand = (_, _, _) async => false;
    final receipt =
        await remote('pause', requestId: 42, source: 'audio-route') as Map;
    expect(receipt['accepted'], isTrue);
    expect(receipt['reason'], 'dispatched');
    expect(receipt['stateMatches'], isFalse);
    expect(receipt['paused'], isFalse);
  });

  test(
    'receipts distinguish stale, inactive, unready and invalid commands',
    () async {
      portal.scripts.clear();
      for (final input in [
        ('pause', 'old-document', null, 'stale-document'),
        ('stop', store.operation.id, null, 'unsupported-action'),
        ('seek', store.operation.id, -1, 'invalid-seek'),
        ('seek', store.operation.id, double.infinity, 'invalid-seek'),
        ('seek', store.operation.id, '240', 'invalid-seek'),
      ]) {
        final receipt =
            await remote(
                  input.$1,
                  document: input.$2,
                  value: input.$3,
                  requestId: 43,
                )
                as Map;
        expect(receipt['accepted'], isFalse);
        expect(receipt['reason'], input.$4);
        expect(receipt['stateMatches'], isNull);
      }
      expect(portal.scripts, isEmpty);
      environment.setForeground(false);
      final background = await remote('pause', requestId: 44) as Map;
      expect(background['reason'], 'not-foreground');
      environment.setForeground(true);
      store.playback.value = const PlaybackState();
      final unready = await remote('pause', requestId: 45) as Map;
      expect(unready['accepted'], isFalse);
      expect(unready['reason'], 'not-operable');
      expect(portal.scripts, isEmpty);
    },
  );

  test(
    'an inactive store rejects commands before its environment is notified',
    () async {
      await store.setApplicationActive(false);
      portal.scripts.clear();
      final receipt = await remote('play', requestId: 46) as Map;
      expect(receipt['accepted'], isFalse);
      expect(receipt['reason'], 'not-foreground');
      expect(portal.scripts, isEmpty);
    },
  );

  test(
    'a delayed command cannot acknowledge state from the next episode',
    () async {
      final finished = Completer<bool>();
      portal.onPlayerCommand = (_, _, _) => finished.future;
      final pending = remote('pause', requestId: 47);
      await flush();
      await store.play(
        const Anime(
          id: '10',
          title: 'Test Anime',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
          latestVideoId: '20',
        ),
        episode: const Episode(id: '21', label: '2'),
      );
      finished.complete(true);
      final receipt = await pending as Map;
      expect(receipt['accepted'], isFalse);
      expect(receipt['reason'], 'session-changed');
      expect(receipt, isNot(contains('paused')));
      expect(receipt, isNot(contains('position')));
    },
  );

  test(
    'toggle receipts describe the resolved action and seek reports its clock',
    () async {
      final toggled = await remote('toggle', requestId: 48) as Map;
      expect(toggled['action'], 'pause');
      expect(toggled['stateMatches'], isFalse);
      portal.onPlayerCommand = (document, action, value) async {
        store.updateNativePlayback(
          document,
          PlaybackState(
            phase: PlaybackPhase.content,
            surfaceReady: true,
            duration: 1200,
            position: value!,
          ),
        );
        return true;
      };
      final sought = await remote('seek', value: 240.5, requestId: 49) as Map;
      expect(sought['accepted'], isTrue);
      expect(sought['stateMatches'], isTrue);
      expect(sought['position'], 240.5);
    },
  );

  test(
    'audio diagnostics are opt-in and never print document or error payloads',
    () async {
      final messages = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message?.startsWith('[BAHA_AUDIO]') == true) {
          messages.add(message!);
        }
      };
      addTearDown(() => debugPrint = previous);
      portal.onPlayerCommand = (_, _, _) async {
        throw StateError('https://signed.invalid/media?token=secret');
      };
      final receipt =
          await remote('pause', requestId: 50, source: 'audio-interruption')
              as Map;
      expect(receipt['stateMatches'], isFalse);
      final enabled = const bool.fromEnvironment('BAHA_DIAGNOSTICS');
      expect(getLast()['diagnostics'], enabled);
      if (enabled) {
        expect(messages, hasLength(1));
        expect(messages.single, contains('"source":"audio-interruption"'));
        expect(messages.single, contains('"requestId":50'));
        expect(messages.single, contains('"stateMatches":false'));
        expect(messages.single, isNot(contains(store.operation.id)));
        expect(messages.single, isNot(contains('secret')));
        expect(messages.single, isNot(contains('signed.invalid')));
      } else {
        expect(messages, isEmpty);
      }
    },
  );
}
