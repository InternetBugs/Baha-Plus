import 'dart:convert';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

class _ProcessPortal extends FakePortal {
  int reloads = 0;
  @override
  Future<void> reload() async => reloads++;
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
  }) => store.receive(
    jsonEncode({
      'type': 'player-state',
      'requestId': store.operation.id,
      'id': '10',
      'videoId': store.playingVideoId,
      'phase': phase,
      'surfaceReady': true,
      'paused': paused,
      'buffering': false,
      'ended': false,
      'muted': true,
      'position': 506.8,
      'duration': 1425.9,
      'buffered': 540,
      'rate': 1.5,
      'qualities': [1080, 720],
      'quality': 1080,
      'checkpointRestored': restored,
    }),
    origin: OfficialSite.home,
    source: OfficialSite.video(store.playingVideoId!),
    isMainFrame: true,
  );

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
