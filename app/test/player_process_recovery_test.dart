import 'dart:async';
import 'dart:convert';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

class _ProcessPortal extends FakePortal {
  int reloads = 0;
  bool failLoad = false;
  Completer<void>? pendingLoad;
  @override
  Future<void> load(Uri uri) async {
    if (failLoad) throw StateError('Player process unavailable');
    await pendingLoad?.future;
    await super.load(uri);
  }

  @override
  Future<void> reload() async => reloads++;
}

class _StoreOwner extends StatefulWidget {
  const _StoreOwner(this.store);
  final AppStore store;
  @override
  State<_StoreOwner> createState() => _StoreOwnerState();
}

class _StoreOwnerState extends State<_StoreOwner> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
  @override
  void dispose() {
    widget.store.dispose();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const anime = Anime(
    id: '10',
    title: 'Test',
    cover: 'https://p2.bahamut.com.tw/10.jpg',
    latestVideoId: '20',
  );

  Future<AppStore> launch(_ProcessPortal portal) async {
    final disk = MemoryStorage()..values['baha.device.quality'] = '1080';
    final store = await AppStore.create(
      storage: disk,
      animeSearch: FakeSearch(),
    );
    addTearDown(store.dispose);
    await store.attach(portal);
    await store.play(anime);
    return store;
  }

  Future<void> report(
    AppStore store, {
    bool paused = false,
    String phase = 'content',
    bool restored = false,
    bool buffering = false,
    double position = 506.8,
    bool recoverable = false,
    bool ended = false,
  }) => store.receive(
    jsonEncode({
      'type': 'player-state',
      'requestId': store.operation.id,
      'id': '10',
      'videoId': store.playingVideoId,
      'phase': phase,
      'surfaceReady': true,
      'paused': paused,
      'buffering': buffering,
      'ended': ended,
      'muted': true,
      'position': position,
      'duration': 1425.9,
      'buffered': 540,
      'rate': 1.5,
      'qualities': [1080, 720],
      'quality': 1080,
      'checkpointRestored': restored,
      'recoverable': recoverable,
    }),
    origin: OfficialSite.home,
    source: OfficialSite.video(store.playingVideoId!),
    isMainFrame: true,
  );

  Future<AppStore> widgetLaunch(
    WidgetTester tester,
    _ProcessPortal portal, {
    bool attachPortal = true,
  }) async {
    final store = (await tester.runAsync(
      () =>
          AppStore.create(storage: MemoryStorage(), animeSearch: FakeSearch()),
    ))!;
    await tester.pumpWidget(_StoreOwner(store));
    if (attachPortal) await store.attach(portal);
    await store.play(anime);
    return store;
  }

  const nativeContent = PlaybackState(
    phase: PlaybackPhase.content,
    surfaceReady: true,
    paused: false,
    buffering: false,
    position: 506.8,
    duration: 1425.9,
    buffered: 540,
    rate: 1.5,
    muted: true,
  );

  testWidgets(
    'an unchanged buffering clock recovers even when state reports keep arriving',
    (tester) async {
      final portal = _ProcessPortal();
      final store = await widgetLaunch(tester, portal);
      await report(store);
      final visits = portal.visited.length;
      for (var i = 0; i < 6; i++) {
        await report(store, buffering: true);
        await tester.pump(const Duration(seconds: 5));
      }
      expect(portal.visited, hasLength(visits + 1));
      expect(portal.visited.last.queryParameters['t'], '506');
      expect(store.playback.value.phase, PlaybackPhase.loading);
    },
  );

  testWidgets('a stalled native clock recovers without any further events', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    store.updateNativePlayback(store.operation.id, nativeContent);
    final visits = portal.visited.length;
    await tester.pump(const Duration(seconds: 30));
    expect(portal.visited, hasLength(visits + 1));
    expect(portal.visited.last.queryParameters['t'], '506');
  });

  testWidgets('native media errors retain the last playing checkpoint', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    store.updateNativePlayback(store.operation.id, nativeContent);
    store.updateNativePlayback(
      store.operation.id,
      const PlaybackState(phase: PlaybackPhase.error),
      recoverable: true,
    );
    await tester.pump(const Duration(seconds: 3));
    expect(portal.visited.last.queryParameters['t'], '506');
    await store.preparePlayerSurface(portal.visited.last);
    expect(
      portal.scripts.any(
        (script) =>
            script.contains('"paused":false') &&
            script.contains('"rate":1.5') &&
            script.contains('"muted":true'),
      ),
      isTrue,
    );
  });

  testWidgets('advancing media resets the stall deadline', (tester) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    final visits = portal.visited.length;
    await report(store);
    await tester.pump(const Duration(seconds: 29));
    await report(store, position: 536);
    await tester.pump(const Duration(seconds: 29));
    expect(portal.visited, hasLength(visits));
    await tester.pump(const Duration(seconds: 1));
    expect(portal.visited.last.queryParameters['t'], '536');
  });

  for (final scenario in ['paused', 'background', 'advertisement', 'denied']) {
    testWidgets('$scenario playback never automatically reloads', (
      tester,
    ) async {
      final portal = _ProcessPortal();
      final store = await widgetLaunch(tester, portal);
      await report(store);
      switch (scenario) {
        case 'paused':
          await report(store, paused: true);
        case 'background':
          await store.setApplicationActive(false);
        case 'advertisement':
          await report(store, phase: 'advertisement');
        case 'denied':
          store.updateNativePlayback(
            store.operation.id,
            const PlaybackState(phase: PlaybackPhase.error),
          );
      }
      final visits = portal.visited.length;
      await tester.pump(const Duration(minutes: 3));
      expect(portal.visited, hasLength(visits));
      expect(portal.reloads, 0);
    });
  }

  testWidgets(
    'successful native recovery clears the deadline and can recover a later crash',
    (tester) async {
      final portal = _ProcessPortal();
      final store = await widgetLaunch(tester, portal);
      final visits = portal.visited.length;
      store.updateNativePlayback(store.operation.id, nativeContent);
      await store.playerProcessTerminated();
      final recovered = store.operation.id;
      store.updateNativePlayback(recovered, nativeContent);
      await report(store); // Stale page clocks cannot replace native state.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 25));
        store.updateNativePlayback(
          recovered,
          const PlaybackState(
            phase: PlaybackPhase.content,
            surfaceReady: true,
            paused: true,
            buffering: false,
            position: 506.8,
            duration: 1425.9,
          ),
        );
      }
      expect(store.playback.value.phase, PlaybackPhase.content);
      store.updateNativePlayback(recovered, nativeContent);
      await store.playerProcessTerminated();
      expect(store.operation.id, isNot(recovered));
      expect(portal.visited, hasLength(visits + 2));
    },
  );

  testWidgets('a crash during recovery is bounded and keeps the checkpoint', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    await report(store);
    final visits = portal.visited.length;
    await store.playerProcessTerminated();
    await store.playerProcessTerminated();
    await store.playerProcessTerminated();
    expect(portal.visited, hasLength(visits + 2));
    expect(store.playback.value.phase, PlaybackPhase.error);
    await store.reloadBrowser();
    expect(portal.visited.last.queryParameters['t'], '506');
  });

  testWidgets('failed recovery navigation exposes retry without throwing', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    await report(store);
    portal.failLoad = true;
    await store.playerProcessTerminated();
    expect(store.playback.value.phase, PlaybackPhase.error);
    portal.failLoad = false;
    await store.reloadBrowser();
    expect(portal.visited.last.queryParameters['t'], '506');
  });

  testWidgets('a pending recovery load cannot leave an endless spinner', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    await report(store);
    final held = portal.pendingLoad = Completer<void>();
    final recovery = store.playerProcessTerminated();
    await tester.pump(const Duration(seconds: 30));
    await recovery;
    expect(store.playback.value.phase, PlaybackPhase.error);
    held.complete();
    await tester.pump();
  });

  testWidgets('a silent initial document eventually exposes retry', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    await tester.pump(const Duration(seconds: 60));
    expect(store.playback.value.phase, PlaybackPhase.error);
  });

  testWidgets('a player without a portal only starts monitoring after attach', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal, attachPortal: false);
    await tester.pump(const Duration(minutes: 2));
    expect(store.playback.value.phase, PlaybackPhase.loading);
    expect(portal.visited, isEmpty);
    await store.attach(portal);
    expect(portal.visited.single, OfficialSite.video('20'));
    await tester.pump(const Duration(seconds: 60));
    expect(store.playback.value.phase, PlaybackPhase.error);
  });

  testWidgets('late decoder state cannot hide an exhausted recovery error', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    for (var attempt = 0; attempt < 3; attempt++) {
      store.updateNativePlayback(store.operation.id, nativeContent);
      await store.playerProcessTerminated();
    }
    final document = store.operation.id;
    final visits = portal.visited.length;
    store.updateNativePlayback(document, nativeContent);
    await report(store, buffering: true);
    await tester.pump(const Duration(minutes: 3));
    expect(store.playback.value.phase, PlaybackPhase.error);
    expect(portal.visited, hasLength(visits));
  });

  testWidgets('completed content never restarts after its process exits', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    await report(store, ended: true);
    final visits = portal.visited.length;
    await store.playerProcessTerminated();
    await tester.pump(const Duration(seconds: 60));
    expect(portal.visited, hasLength(visits));
    expect(store.playback.value.phase, PlaybackPhase.error);
  });

  testWidgets('recovery timeout retains the checkpoint for manual retry', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    await report(store);
    await store.playerProcessTerminated();
    final timedOut = store.operation.id;
    await tester.pump(const Duration(minutes: 2));
    expect(store.playback.value.phase, PlaybackPhase.error);
    store.updateNativePlayback(timedOut, nativeContent);
    expect(store.playback.value.phase, PlaybackPhase.error);
    await store.reloadBrowser();
    expect(portal.visited.last.queryParameters['t'], '506');
  });

  testWidgets('official episode navigation discards the old checkpoint', (
    tester,
  ) async {
    final portal = _ProcessPortal();
    final store = await widgetLaunch(tester, portal);
    await report(store);
    store.playerDetail = AnimeDetail.fromJson({
      'title': anime.title,
      'description': '',
      'episodes': [
        {'id': '20', 'label': '1'},
        {'id': '21', 'label': '2'},
      ],
      'metadata': <Json>[],
    });
    store.updateNavigation(OfficialSite.video('21'), canGoBack: true);
    final visits = portal.visited.length;
    await store.playerProcessTerminated();
    expect(portal.visited, hasLength(visits));
    await store.reloadBrowser();
    expect(portal.reloads, 1);
    await store.preparePlayerSurface(OfficialSite.video('21'));
    expect(
      portal.scripts.any(
        (script) => script.contains('window.__bahaPlaybackCheckpoint = null'),
      ),
      isTrue,
    );
  });

  test(
    'a foreground content process termination restores the current episode and checkpoint',
    () async {
      final portal = _ProcessPortal();
      final store = await launch(portal);
      await report(store);
      final previous = store.operation.id;
      final visits = portal.visited.length;
      await store.playerProcessTerminated();
      expect(store.operation.id, isNot(previous));
      expect(portal.visited, hasLength(visits + 1));
      expect(portal.visited.last.queryParameters, {'sn': '20', 't': '506'});
      expect(store.playback.value.phase, PlaybackPhase.loading);
      await store.preparePlayerSurface(portal.visited.last);
      expect(
        portal.scripts.any(
          (script) =>
              script.contains('"position":506.8') &&
              script.contains('"rate":1.5') &&
              script.contains('"muted":true'),
        ),
        isTrue,
      );
      await report(store, restored: true);
      expect(store.playback.value.position, 506.8);
      expect(store.playback.value.rate, 1.5);
    },
  );

  test(
    'a background termination waits for an explicit retry and preserves pause',
    () async {
      final portal = _ProcessPortal();
      final store = await launch(portal);
      await report(store);
      await store.setApplicationActive(false);
      final visits = portal.visited.length;
      await store.playerProcessTerminated();
      expect(portal.visited, hasLength(visits));
      expect(store.playback.value.phase, PlaybackPhase.error);
      await store.setApplicationActive(true);
      expect(portal.visited, hasLength(visits));
      await store.reloadBrowser();
      expect(portal.visited.last.queryParameters['t'], '506');
      await store.preparePlayerSurface(portal.visited.last);
      expect(
        portal.scripts.any(
          (script) =>
              script.contains('"paused":true') &&
              script.contains('window.__bahaPlaybackCheckpoint'),
        ),
        isTrue,
      );
    },
  );

  test(
    'native process recovery never reloads the media session without an explicit retry',
    () async {
      final portal = _ProcessPortal();
      final store = await launch(portal);
      await report(store);
      final document = store.operation.id;
      final visits = portal.visited.length;
      await store.playerProcessTerminated(allowAutomaticReload: false);
      expect(store.operation.id, document);
      expect(portal.visited, hasLength(visits));
      expect(portal.reloads, 0);
      expect(store.playback.value.phase, PlaybackPhase.error);
      await store.reloadBrowser();
      expect(portal.visited, hasLength(visits + 1));
      expect(portal.visited.last.queryParameters['t'], '506');
    },
  );

  test(
    'advertisements cannot reuse a content checkpoint or automatically restart',
    () async {
      final portal = _ProcessPortal();
      final store = await launch(portal);
      await report(store, phase: 'advertisement');
      final visits = portal.visited.length;
      await store.playerProcessTerminated();
      expect(portal.visited, hasLength(visits));
      await store.reloadBrowser();
      expect(portal.reloads, 1);
      expect(portal.visited, hasLength(visits));
    },
  );

  test(
    'repeated process crashes have a bounded number of automatic recoveries',
    () async {
      final portal = _ProcessPortal();
      final store = await launch(portal);
      final visits = portal.visited.length;
      for (var i = 0; i < 3; i++) {
        await report(store, restored: true);
        await store.playerProcessTerminated();
      }
      expect(portal.visited, hasLength(visits + 2));
      expect(store.playback.value.phase, PlaybackPhase.error);
    },
  );

  test(
    'changing episodes discards the terminated episode checkpoint',
    () async {
      final portal = _ProcessPortal();
      final store = await launch(portal);
      await report(store, paused: true);
      await store.playerProcessTerminated();
      await store.play(
        anime,
        episode: const Episode(id: '21', label: '2'),
      );
      await store.preparePlayerSurface(OfficialSite.video('21'));
      expect(portal.visited.last.queryParameters, {'sn': '21'});
      expect(
        portal.scripts.any(
          (script) => script.contains('window.__bahaPlaybackCheckpoint = null'),
        ),
        isTrue,
      );
    },
  );
}
