import 'fake_metadata.dart';
import 'dart:async';
import 'dart:convert';

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

const _anime = Anime(
  id: '10',
  title: 'Test Anime',
  cover: 'https://p2.bahamut.com.tw/10.jpg',
  latestVideoId: '20',
);
const _preferenceKey = 'baha.device.quality';

class _DelayedStorage extends MemoryStorage {
  final firstWrite = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<void> write(String key, String value) async {
    if (key == _preferenceKey && !firstWrite.isCompleted) {
      firstWrite.complete();
      await releaseWrite.future;
    }
    await super.write(key, value);
  }
}

class _FailingPortal extends FakePortal {
  bool failQuality = true;

  @override
  Future<dynamic> evaluate(String script) async {
    final result = await super.evaluate(script);
    if (failQuality && script.contains('"quality"')) {
      failQuality = false;
      throw StateError('Document was replaced');
    }
    return result;
  }
}

class _RejectingPortal extends FakePortal {
  bool reject = true;

  @override
  Future<bool> playerCommand(
    String document,
    String action,
    double? value,
  ) async {
    await super.playerCommand(document, action, value);
    return action != 'quality' || !reject;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppStore> launch(MemoryStorage disk, FakePortal portal) async {
    final store = await AppStore.create(
      metadataApi: FakeMetadata(),
      storage: disk,
      animeSearch: FakeSearch(),
    );
    addTearDown(store.dispose);
    await store.attach(portal);
    await store.play(_anime);
    portal.scripts.clear();
    return store;
  }

  Future<void> state(
    AppStore store, {
    String phase = 'content',
    List<int> qualities = const [1080, 720, 360],
    int quality = 0,
  }) => store.receive(
    jsonEncode({
      'type': 'player-state',
      'requestId': store.operation.id,
      'id': store.playingAnime!.id,
      'videoId': store.playingVideoId,
      'phase': phase,
      'surfaceReady': true,
      'paused': true,
      'buffering': false,
      'ended': false,
      'muted': false,
      'position': 37,
      'duration': 1200,
      'buffered': 90,
      'rate': 1,
      'qualities': qualities,
      'quality': quality,
    }),
    origin: OfficialSite.home,
    source: OfficialSite.video(store.playingVideoId!),
    isMainFrame: true,
  );

  List<String> qualityCommands(FakePortal portal) =>
      portal.scripts.where((script) => script.contains('"quality"')).toList();

  test(
    'a quality selection survives restart and waits for content levels',
    () async {
      final disk = MemoryStorage();
      final portal = FakePortal();
      final store = await launch(disk, portal);
      await state(store);
      await store.controlPlayer('quality', 1080);
      expect(disk.values[_preferenceKey], '1080');
      expect(qualityCommands(portal).single, contains('"quality",1080.0'));

      final restartedPortal = FakePortal();
      final restarted = await launch(disk, restartedPortal);
      await state(restarted, phase: 'loading');
      await state(restarted, phase: 'age');
      await state(restarted, phase: 'advertisement');
      await state(restarted, qualities: []);
      expect(qualityCommands(restartedPortal), isEmpty);

      final request = restarted.operation;
      final navigations = restartedPortal.visited.length;
      await state(restarted);
      expect(
        qualityCommands(restartedPortal).single,
        contains('"${request.id}","quality",1080.0'),
      );
      // Reports arriving before the asynchronous native switch completes must
      // not restart that switch or replace the existing playback session.
      await state(restarted);
      await state(restarted, quality: 1080);
      expect(qualityCommands(restartedPortal), hasLength(1));
      expect(restarted.operation, same(request));
      expect(restartedPortal.visited, hasLength(navigations));
      expect(restarted.playback.value.position, 37);
      expect(restarted.playback.value.buffered, 90);
      expect(disk.values[_preferenceKey], '1080');
    },
  );

  test(
    'the saved quality restores for episodes, reloads and other series',
    () async {
      final disk = MemoryStorage()..values[_preferenceKey] = '720';
      final portal = FakePortal();
      final store = await launch(disk, portal);
      await state(store);
      await store.play(
        _anime,
        episode: const Episode(id: '21', label: '2'),
      );
      final nextEpisode = store.operation.id;
      await state(store);
      await store.reloadBrowser();
      final reloaded = store.operation.id;
      await state(store);
      await store.play(
        const Anime(
          id: '11',
          title: 'Another Anime',
          cover: 'https://p2.bahamut.com.tw/11.jpg',
          latestVideoId: '30',
        ),
      );
      await state(store);
      expect(qualityCommands(portal), hasLength(4));
      expect(
        qualityCommands(
          portal,
        ).every((script) => script.contains('"quality",720.0')),
        isTrue,
      );
      expect(qualityCommands(portal)[1], contains(nextEpisode));
      expect(qualityCommands(portal)[2], contains(reloaded));
    },
  );

  test('official episode navigation also restores the saved quality', () async {
    final disk = MemoryStorage()..values[_preferenceKey] = '720';
    final portal = FakePortal();
    final store = await launch(disk, portal);
    store.playerDetail = AnimeDetail.fromJson({
      'title': 'Test Anime',
      'description': '',
      'episodes': [
        {'id': '20', 'label': '1'},
        {'id': '21', 'label': '2'},
      ],
      'metadata': [],
    });
    await state(store);
    store.updateNavigation(OfficialSite.video('21'), canGoBack: true);
    await state(store);
    expect(qualityCommands(portal), hasLength(2));
    expect(qualityCommands(portal).last, contains(store.operation.id));
    expect(store.playingVideoId, '21');
  });

  test(
    'unavailable resolutions do not overwrite the saved preference',
    () async {
      final disk = MemoryStorage()..values[_preferenceKey] = '1080';
      final portal = FakePortal();
      final store = await launch(disk, portal);
      await state(store, qualities: [720, 360]);
      expect(qualityCommands(portal), isEmpty);
      expect(store.playback.value.quality, 0);
      expect(disk.values[_preferenceKey], '1080');

      await state(store);
      expect(qualityCommands(portal).single, contains('"quality",1080.0'));
      expect(disk.values[_preferenceKey], '1080');
    },
  );

  test(
    'choosing automatic replaces the saved resolution across restart',
    () async {
      final disk = MemoryStorage()..values[_preferenceKey] = '1080';
      final portal = FakePortal();
      final store = await launch(disk, portal);
      await state(store, quality: 1080);
      await store.controlPlayer('quality', 0);
      expect(disk.values[_preferenceKey], '0');
      await state(store);
      expect(qualityCommands(portal).single, contains('"quality",0.0'));

      final restartedPortal = FakePortal();
      final restarted = await launch(disk, restartedPortal);
      await state(restarted, quality: 1080);
      await state(restarted);
      expect(
        qualityCommands(restartedPortal).single,
        contains('"quality",0.0'),
      );
      expect(disk.values[_preferenceKey], '0');
    },
  );

  test(
    'invalid and blocked quality commands cannot change the preference',
    () async {
      final disk = MemoryStorage()..values[_preferenceKey] = '720';
      final portal = FakePortal();
      final store = await launch(disk, portal);
      await state(store, quality: 720);
      for (final value in [
        null,
        -1.0,
        1080.5,
        1440.0,
        double.nan,
        double.infinity,
      ]) {
        await store.controlPlayer('quality', value);
      }
      await state(store, phase: 'advertisement');
      await store.controlPlayer('quality', 1080);
      await state(store, phase: 'loading');
      await store.controlPlayer('quality', 1080);
      await state(store, quality: 720);
      await store.setApplicationActive(false);
      await store.controlPlayer('quality', 1080);
      expect(qualityCommands(portal), isEmpty);
      expect(disk.values[_preferenceKey], '720');
    },
  );

  test('restoration waits for foreground without starting playback', () async {
    final disk = MemoryStorage()..values[_preferenceKey] = '1080';
    final portal = FakePortal();
    final store = await launch(disk, portal);
    await store.setApplicationActive(false);
    await state(store);
    expect(qualityCommands(portal), isEmpty);
    await store.setApplicationActive(true);
    expect(qualityCommands(portal).single, contains('"quality",1080.0'));
    expect(portal.scripts.any((script) => script.contains('"play"')), isFalse);
    expect(store.playback.value.paused, isTrue);
    await state(store);
    expect(qualityCommands(portal), hasLength(1));
  });

  test(
    'rapid selections persist in order while controls stay responsive',
    () async {
      final disk = _DelayedStorage();
      final portal = FakePortal();
      final store = await launch(disk, portal);
      await state(store);
      final first = store.controlPlayer('quality', 1080);
      await disk.firstWrite.future;
      final second = store.controlPlayer('quality', 720);
      expect(qualityCommands(portal), hasLength(2));
      disk.releaseWrite.complete();
      await Future.wait([first, second]);
      expect(disk.values[_preferenceKey], '720');

      final restartedPortal = FakePortal();
      final restarted = await launch(disk, restartedPortal);
      await state(restarted);
      expect(
        qualityCommands(restartedPortal).single,
        contains('"quality",720.0'),
      );
    },
  );

  test(
    'an interrupted bridge can retry without discarding playback state',
    () async {
      final disk = MemoryStorage()..values[_preferenceKey] = '1080';
      final portal = _FailingPortal();
      final store = await launch(disk, portal);
      await state(store);
      expect(store.playback.value.phase, PlaybackPhase.content);
      expect(store.playback.value.position, 37);
      await state(store);
      await state(store, quality: 1080);
      expect(qualityCommands(portal), hasLength(2));
      expect(disk.values[_preferenceKey], '1080');
    },
  );

  test(
    'a rejected switch is retried for a new document and a later manual choice',
    () async {
      final disk = MemoryStorage()..values[_preferenceKey] = '1080';
      final portal = _RejectingPortal();
      final store = await launch(disk, portal);
      await state(store);
      await state(store);
      // Repeated state messages cannot hammer a failed switch.
      expect(qualityCommands(portal), hasLength(1));
      expect(store.playback.value.quality, 0);
      expect(disk.values[_preferenceKey], '1080');
      await store.play(
        _anime,
        episode: const Episode(id: '21', label: '2'),
      );
      portal.reject = false;
      await state(store);
      expect(qualityCommands(portal), hasLength(2));
      await store.controlPlayer('quality', 720);
      expect(qualityCommands(portal), hasLength(3));
      expect(disk.values[_preferenceKey], '720');
    },
  );

  test(
    'missing or damaged quality preferences fall back to automatic',
    () async {
      for (final saved in [
        null,
        '',
        '1080.5',
        '-1',
        '100',
        '4321',
        'invalid',
      ]) {
        final disk = MemoryStorage();
        if (saved != null) disk.values[_preferenceKey] = saved;
        final portal = FakePortal();
        final store = await launch(disk, portal);
        await state(store, quality: 720);
        expect(qualityCommands(portal).single, contains('"quality",0.0'));
        expect(disk.values[_preferenceKey], saved);
      }
    },
  );

  test(
    'the document-start script receives every saved fixed quality and automatic mode',
    () async {
      for (final height in [0, 360, 540, 720, 1080]) {
        final disk = MemoryStorage()..values[_preferenceKey] = '$height';
        final store = await launch(disk, FakePortal());
        expect(store.preferredQuality, height);
        expect(
          store.initialQualityScript,
          contains('window.__bahaPreferredQuality = $height;'),
        );
        expect(store.initialQualityScript, isNot(contains('%QUALITY%')));
      }
    },
  );
}
