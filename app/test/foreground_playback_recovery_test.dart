import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'fake_metadata.dart';

class _Owner extends StatefulWidget {
  const _Owner(this.store);
  final AppStore store;
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
  @override
  void dispose() {
    widget.store.dispose();
    super.dispose();
  }
}

class _ResumePortal extends FakePortal {
  int plays = 0, loads = 0;
  bool acceptPlay = true, failLoads = false;

  @override
  Future<bool> playerCommand(
    String document,
    String action,
    double? value,
  ) async {
    if (action == 'play') {
      plays++;
      return acceptPlay;
    }
    return super.playerCommand(document, action, value);
  }

  @override
  Future<void> load(Uri uri) async {
    loads++;
    if (failLoads) throw StateError('Offline');
    await super.load(uri);
  }
}

const _playing = PlaybackState(
  phase: PlaybackPhase.content,
  surfaceReady: true,
  paused: false,
  buffering: false,
  position: 42,
  duration: 1200,
  buffered: 120,
  rate: 1.5,
  muted: true,
  qualities: [1080, 360],
  quality: 1080,
);
const _paused = PlaybackState(
  phase: PlaybackPhase.content,
  surfaceReady: true,
  paused: true,
  buffering: false,
  position: 42,
  duration: 1200,
  buffered: 120,
  rate: 1.5,
  muted: true,
  qualities: [1080, 360],
  quality: 1080,
);

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.iOS,
    TargetPlatform.android,
  });

  Future<(AppStore, _ResumePortal)> launch(WidgetTester tester) async {
    final store = (await tester.runAsync(
      () => AppStore.create(
        metadataApi: FakeMetadata(),
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
      ),
    ))!;
    await tester.pumpWidget(_Owner(store));
    final portal = _ResumePortal();
    await store.attach(portal);
    await store.play(
      const Anime(
        id: '10',
        title: 'Test',
        cover: 'https://p2.bahamut.com.tw/10.jpg',
        latestVideoId: '20',
      ),
    );
    store.updateNativePlayback(store.operation.id, _playing);
    await store.setApplicationActive(false);
    store.updateNativePlayback(store.operation.id, _paused);
    await store.setApplicationActive(true);
    expect(store.playback.value.paused, isTrue);
    expect(portal.plays, 0);
    return (store, portal);
  }

  testWidgets('foreground play reuses a healthy session and its buffer', (
    tester,
  ) async {
    final (store, portal) = await launch(tester);
    final document = store.operation.id;
    await store.controlPlayer('play');
    expect(portal.plays, 1);
    expect(store.resumingPlayback, isTrue);
    expect(store.playback.value.phase, PlaybackPhase.loading);
    store.updateNativePlayback(document, _playing);
    expect(store.resumingPlayback, isFalse);
    expect(store.playback.value.paused, isFalse);
    expect(store.playback.value.buffered, 120);
    expect(store.operation.id, document);
    expect(portal.loads, 1);
    // No retry timer survives successful playback.
    await store.setApplicationActive(false);
    await tester.pump(const Duration(seconds: 31));
    expect(portal.loads, 1);
  }, variant: platforms);

  testWidgets('a background process loss resumes from the play button', (
    tester,
  ) async {
    final (store, portal) = await launch(tester);
    await store.setApplicationActive(false);
    await store.playerProcessTerminated();
    await store.setApplicationActive(true);
    expect(store.playback.value.phase, PlaybackPhase.content);
    expect(store.playback.value.paused, isTrue);
    expect(portal.loads, 1);
    await store.controlPlayer('play');
    expect(portal.loads, 2);
    expect(portal.visited.last.queryParameters['t'], '42');
    await store.preparePlayerSurface(portal.visited.last);
    expect(
      portal.scripts.any(
        (s) =>
            s.contains('window.__bahaPlaybackCheckpoint = {') &&
            s.contains('"paused":false'),
      ),
      isTrue,
    );
    store.updateNativePlayback(store.operation.id, _playing);
    expect(store.resumingPlayback, isFalse);
    expect(store.playback.value.rate, 1.5);
    expect(store.playback.value.muted, isTrue);
  }, variant: platforms);

  testWidgets('transient failures get only two extra attempts before retry', (
    tester,
  ) async {
    final (store, portal) = await launch(tester);
    portal.acceptPlay = false;
    portal.failLoads = true;
    await store.controlPlayer('play');
    expect(store.playback.value.phase, PlaybackPhase.loading);
    await tester.pump(const Duration(milliseconds: 250));
    expect(portal.loads, 2);
    expect(store.playback.value.phase, PlaybackPhase.loading);
    await tester.pump(const Duration(milliseconds: 250));
    expect(portal.loads, 3);
    expect(store.resumingPlayback, isFalse);
    expect(store.playback.value.phase, PlaybackPhase.error);
    await tester.pump(const Duration(seconds: 31));
    expect(portal.loads, 3);
    portal.failLoads = false;
    await store.retryPlayback();
    expect(store.resumingPlayback, isTrue);
    expect(portal.loads, 4);
    expect(portal.visited.last.queryParameters['t'], '42');
  }, variant: platforms);

  testWidgets(
    'silent attempts end at 30 seconds and reject late decoder state',
    (tester) async {
      final (store, portal) = await launch(tester);
      await store.controlPlayer('play');
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 250));
      expect(portal.loads, 2);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 250));
      expect(portal.loads, 3);
      final pending = store.operation.id;
      await tester.pump(const Duration(milliseconds: 9500));
      expect(store.resumingPlayback, isFalse);
      expect(store.playback.value.phase, PlaybackPhase.error);
      expect(store.operation.id, isNot(pending));
      store.updateNativePlayback(pending, _playing);
      expect(store.playback.value.phase, PlaybackPhase.error);
      expect(portal.loads, 3);
    },
    variant: platforms,
  );

  testWidgets(
    'background cancels recovery and late completion cannot autoplay',
    (tester) async {
      final (store, portal) = await launch(tester);
      await store.controlPlayer('play');
      final pending = store.operation.id;
      await store.setApplicationActive(false);
      store.updateNativePlayback(pending, _playing);
      await tester.pump(const Duration(seconds: 31));
      expect(store.resumingPlayback, isFalse);
      expect(portal.loads, 1);
      expect(store.playback.value.paused, isTrue);
      await store.setApplicationActive(true);
      expect(portal.plays, 1);
      expect(store.playback.value.paused, isTrue);
      await store.controlPlayer('play');
      expect(portal.loads, 2);
    },
    variant: platforms,
  );

  testWidgets('official denial ends automatic retries immediately', (
    tester,
  ) async {
    final (store, portal) = await launch(tester);
    await store.controlPlayer('play');
    store.updateNativePlayback(
      store.operation.id,
      const PlaybackState(phase: PlaybackPhase.error),
    );
    expect(store.resumingPlayback, isFalse);
    expect(store.playback.value.phase, PlaybackPhase.error);
    await tester.pump(const Duration(seconds: 31));
    expect(portal.loads, 1);
  }, variant: platforms);

  testWidgets(
    'official prompts use their existing flow outside the technical timeout',
    (tester) async {
      final (store, portal) = await launch(tester);
      await store.controlPlayer('play');
      store.updateNativePlayback(
        store.operation.id,
        const PlaybackState(phase: PlaybackPhase.advertisement),
      );
      expect(store.resumingPlayback, isFalse);
      await tester.pump(const Duration(seconds: 31));
      expect(store.playback.value.phase, PlaybackPhase.advertisement);
      expect(portal.loads, 1);
    },
    variant: platforms,
  );

  testWidgets('changing episodes cancels the old recovery round', (
    tester,
  ) async {
    final (store, portal) = await launch(tester);
    await store.controlPlayer('play');
    final previous = store.operation.id;
    await store.play(
      store.playingAnime!,
      episode: const Episode(id: '21', label: '2'),
    );
    store.updateNativePlayback(previous, _playing);
    await tester.pump(const Duration(seconds: 31));
    expect(store.playingVideoId, '21');
    expect(store.resumingPlayback, isFalse);
    expect(portal.loads, 2);
  }, variant: platforms);
}
