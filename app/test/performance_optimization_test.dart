import 'dart:async';

import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/danmaku_animation.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/core/search_folding.dart';
import 'package:baha_plus/data/app_diagnostics.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/device_storage.dart';
import 'package:baha_plus/data/native_http_playback.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/data/playback_environment.dart';
import 'package:baha_plus/ui/comments_preview.dart';
import 'package:baha_plus/ui/danmaku_panel.dart';
import 'package:baha_plus/ui/glass_settings_menu.dart';
import 'package:baha_plus/ui/native_http_player.dart';
import 'package:baha_plus/ui/native_video_surface.dart';
import 'package:baha_plus/ui/synopsis_section.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'fake_metadata.dart';
import 'fake_playback.dart';
import 'native_http_api_test.dart' show HttpFixture;
import 'native_playback_test.dart' show FakeVideo, sourceJson;

PlaybackState _contentState({
  double position = 10,
  double duration = 1200,
  bool paused = false,
}) => PlaybackState(
  phase: PlaybackPhase.content,
  surfaceReady: true,
  paused: paused,
  position: position,
  duration: duration,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'NativeHttpPlayback suppresses ChangeNotifier spam on routine playback ticks',
    () async {
      final video = FakeVideo();
      VideoPlayerPlatform.instance = video;
      final fixture = HttpFixture(ads: false);
      final published = <PlaybackState>[];
      var now = Duration.zero;
      final session = NativeHttpPlayback(
        document: 'quiet-ticks',
        videoId: '40190',
        preferredQuality: 0,
        diagnostics: AppDiagnostics.instance,
        api: fixture.api(),
        now: () => now,
        onState: published.add,
      );
      addTearDown(session.close);
      await session.prepare();
      await session.consent();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      var notifications = 0;
      session.addListener(() => notifications++);
      published.clear();

      final controller = session.player!.video!;
      for (var ms = 10100; ms <= 15000; ms += 100) {
        now = Duration(milliseconds: ms - 10000);
        controller.value = controller.value.copyWith(
          position: Duration(milliseconds: ms),
          isPlaying: true,
        );
      }
      expect(published, hasLength(50));
      expect(notifications, 0);
    },
  );

  test(
    'NativeHttpPlayback notifies at most once per ad countdown second',
    () async {
      final video = FakeVideo();
      VideoPlayerPlatform.instance = video;
      final fixture = HttpFixture(ads: true);
      final session = NativeHttpPlayback(
        document: 'ad-ticks',
        videoId: '40190',
        preferredQuality: 0,
        diagnostics: AppDiagnostics.instance,
        api: fixture.api(),
        onState: (_) {},
      );
      addTearDown(session.close);
      await session.prepare();
      await session.consent();

      final controller = session.player!.video!;
      controller.value = controller.value.copyWith(
        position: const Duration(milliseconds: 500),
        isPlaying: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      var notifications = 0;
      session.addListener(() => notifications++);
      for (final ms in [1100, 1250, 1500, 1900]) {
        controller.value = controller.value.copyWith(
          position: Duration(milliseconds: ms),
          isPlaying: true,
        );
      }
      expect(notifications, 1);

      notifications = 0;
      for (final ms in [2100, 2300, 2600, 2900]) {
        controller.value = controller.value.copyWith(
          position: Duration(milliseconds: ms),
          isPlaying: true,
        );
      }
      expect(notifications, 1);
    },
  );

  test(
    'NativePlayback memoizes state and invalidates on buffer, position, seek and quality updates',
    () async {
      final video = FakeVideo();
      VideoPlayerPlatform.instance = video;
      final native = NativePlayback(
        document: 'state-memo',
        source: NativePlaybackSource.fromJson(sourceJson()),
        userAgent: 'device agent',
        onState: (_) {},
      );
      addTearDown(native.dispose);
      await native.initialize(0);
      await native.activate(
        applicationActive: true,
        timeline: {'position': 0, 'paused': false, 'rate': 1, 'muted': false},
      );

      final firstState = native.state;
      final secondState = native.state;
      expect(identical(firstState, secondState), isTrue);
      expect(identical(firstState.qualities, secondState.qualities), isTrue);
      expect(native.duration, firstState.duration);
      expect(native.isPaused, firstState.paused);

      video.streams[0]!.add(
        VideoEvent(
          eventType: VideoEventType.bufferingUpdate,
          buffered: [
            DurationRange(Duration.zero, const Duration(seconds: 30)),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final bufferedState = native.state;
      expect(identical(bufferedState, firstState), isFalse);
      expect(bufferedState.bufferedRanges, [(start: 0.0, end: 30.0)]);
      expect(identical(native.state, bufferedState), isTrue);

      await native.command('seek', 120);
      final soughtState = native.state;
      expect(identical(soughtState, bufferedState), isFalse);
      expect(soughtState.position, 120);

      await native.command('quality', 360);
      final qualityState = native.state;
      expect(identical(qualityState, soughtState), isFalse);
      expect(qualityState.quality, 360);
    },
  );

  test(
    'PlaybackEnvironment avoids 1Hz IPC during steady playback and syncs on drift or state transitions',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const channel = MethodChannel('app.bahaplus.mobile/playback_environment');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final updates = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        updates.add(call.arguments as Map);
        return null;
      });
      final store = await AppStore.create(
        nativeHttpApiFactory: PendingNativeHttpApi.new,
        metadataApi: FakeMetadata(),
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
      );
      addTearDown(() {
        store.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      await store.attach(FakePortal());
      await playFixture(
        store,
        const Anime(
          id: '10',
          title: 'Test Anime',
          cover: '',
          latestVideoId: '20',
        ),
      );

      var now = Duration.zero;
      store.playback.value = _contentState(position: 10);
      final env = PlaybackEnvironment(store, now: () => now);
      addTearDown(env.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(updates, hasLength(1));

      // 10 seconds of steady 1x playback should not emit repeated IPC updates.
      for (var s = 1; s <= 10; s++) {
        now = Duration(seconds: s);
        store.playback.value = _contentState(position: 10.0 + s);
      }
      await Future<void>.delayed(Duration.zero);
      expect(updates, hasLength(1));

      // A large clock jump / seek exceeding 2s drift triggers an update immediately.
      store.playback.value = _contentState(position: 45.0);
      await Future<void>.delayed(Duration.zero);
      expect(updates, hasLength(2));
      expect(updates.last['position'], 45);

      // Pausing triggers an immediate update.
      store.playback.value = _contentState(position: 45.0, paused: true);
      await Future<void>.delayed(Duration.zero);
      expect(updates, hasLength(3));
      expect(updates.last['playing'], isFalse);
    },
  );

  test(
    'AppStore derived caches and SearchFolding normalization stay consistent across mutations',
    () {
      final folding = SearchFolding({'a': 'b'});
      expect(folding.normalize('A Test!'), 'btest');
      expect(folding.normalize('A Test!'), 'btest');

      final animeA = const Anime(
        id: '1',
        title: 'Alpha Show',
        cover: '',
        sections: ['season'],
      );
      final animeB = const Anime(
        id: '2',
        title: 'Beta Show',
        cover: '',
        sections: ['hot'],
      );
      final store = AppStore(
        storage: MemoryStorage(),
        dictionaries: const {},
        folding: folding,
        scripts: const {},
        animeSearch: FakeSearch(),
        metadataApi: FakeMetadata(),
        catalog: Catalog(items: [animeA, animeB]),
      );
      addTearDown(store.dispose);

      final seasonal1 = store.seasonal;
      final popular1 = store.popular;
      final seasonalPopular1 = store.seasonalPopular;
      final newAdded1 = store.newAdded;
      final thematic1 = store.thematicCollections;
      final homeFeed1 = store.homeFeed;
      expect(identical(seasonal1, store.seasonal), isTrue);
      expect(identical(popular1, store.popular), isTrue);
      expect(identical(seasonalPopular1, store.seasonalPopular), isTrue);
      expect(identical(newAdded1, store.newAdded), isTrue);
      expect(identical(thematic1, store.thematicCollections), isTrue);
      expect(identical(homeFeed1, store.homeFeed), isTrue);
      expect(seasonal1.map((e) => e.id), ['1']);
      expect(popular1.map((e) => e.id), ['2']);

      expect(store.isFavorite(animeA), isFalse);
      store.favorites = [animeA];
      expect(store.isFavorite(animeA), isTrue);
      expect(store.isFavorite(animeB), isFalse);

      store.selectTab(2, filter: 'favorites');
      final lib1 = store.libraryItems;
      expect(identical(lib1, store.libraryItems), isTrue);
      expect(lib1.map((e) => e.id), ['1']);

      store.notifications = [
        AnimeNotification.fromJson({
          'id': 'n1',
          'videoId': '101',
          'title': 'Ep 1',
          'time': 'now',
          'cover': null,
        }),
        AnimeNotification.fromJson({
          'id': 'n2',
          'videoId': '102',
          'title': 'Ep 2',
          'time': 'now',
          'cover': null,
        }),
      ];
      expect(store.unreadNotifications, 2);
      store.catalog = Catalog(items: [animeB]);
      expect(store.seasonal, isEmpty);
      expect(store.popular.map((e) => e.id), ['2']);
    },
  );

  testWidgets(
    'PlayerPage isolates playback position ticks from chrome containers and hidden fullscreen controls',
    (tester) async {
      final video = FakeVideo();
      VideoPlayerPlatform.instance = video;
      final fixture = HttpFixture(ads: false);
      tester.view.physicalSize = const Size(850, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final store = (await tester.runAsync(
        () => AppStore.create(
          nativeHttpApiFactory: fixture.api,
          metadataApi: FakeMetadata(),
          storage: MemoryStorage(),
          animeSearch: FakeSearch(),
        ),
      ))!;
      addTearDown(() async {
        await tester.runAsync(store.closeBrowser);
        store.dispose();
      });

      await tester.runAsync(
        () => store.play(
          const Anime(
            id: '10',
            title: 'Opt Show',
            cover: '',
            latestVideoId: '40190',
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.runAsync(store.nativeHttpPlayback!.consent);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );

      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MaterialApp(home: NativeHttpPlayer(store: store)),
        ),
      );
      await tester.pump();

      final controlsFinder = find.byKey(const ValueKey('video-glass-controls'));
      final toggleFinder = find.byKey(const ValueKey('player-controls-toggle'));
      final danmakuFinder = find.byKey(const ValueKey('player-danmaku-button'));
      final settingsFinder = find.byType(GlassSettingsMenu);
      final sliderFinder = find.byKey(const ValueKey('player-progress-slider'));

      final controlsBefore = tester.widget(controlsFinder);
      final toggleBefore = tester.widget(toggleFinder);
      final danmakuBefore = tester.widget(danmakuFinder);
      final settingsBefore = tester.widget(settingsFinder);

      // Push 10 position ticks; surrounding glass containers, gesture detector, and
      // menus must remain identical instances without rebuilding.
      final controller = store.nativeHttpPlayback!.player!.video!;
      for (var i = 1; i <= 10; i++) {
        controller.value = controller.value.copyWith(
          position: Duration(seconds: 10 + i),
          isPlaying: true,
        );
      }
      await tester.pump();
      expect(identical(tester.widget(controlsFinder), controlsBefore), isTrue);
      expect(identical(tester.widget(toggleFinder), toggleBefore), isTrue);
      expect(identical(tester.widget(danmakuFinder), danmakuBefore), isTrue);
      expect(identical(tester.widget(settingsFinder), settingsBefore), isTrue);
      expect(tester.widget<GlassSlider>(sliderFinder).value, 20);

      // Switch to fullscreen and wait past the 3-second auto-hide timer.
      store.setPlayerFullscreen(true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 150));
      expect(controlsFinder.hitTestable(), findsNothing);

      // Position ticks while fullscreen controls are hidden do not rebuild the hidden slider.
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 75),
        isPlaying: true,
      );
      await tester.pump();
      expect(tester.widget<GlassSlider>(sliderFinder).value, 20);

      // Tapping to reveal (after double-tap disambiguation delay) immediately
      // synchronizes the slider to the live clock.
      await tester.tap(toggleFinder);
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.widget<GlassSlider>(sliderFinder).value, 75);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'NativePlayback reuses merged bufferedRanges across position ticks and NativeHttpPlayback projects content zero-copy',
    () async {
      final video = FakeVideo();
      VideoPlayerPlatform.instance = video;
      final fixture = HttpFixture(ads: false);
      final session = NativeHttpPlayback(
        document: 'zero-copy-project',
        videoId: '40190',
        preferredQuality: 0,
        diagnostics: AppDiagnostics.instance,
        api: fixture.api(),
        onState: (_) {},
      );
      addTearDown(session.close);
      await session.prepare();
      await session.consent();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final player = session.player!;
      video.streams[0]!.add(
        VideoEvent(
          eventType: VideoEventType.bufferingUpdate,
          buffered: [
            DurationRange(Duration.zero, const Duration(seconds: 60)),
            DurationRange(
              const Duration(seconds: 120),
              const Duration(seconds: 180),
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final initialRanges = player.state.bufferedRanges;
      expect(initialRanges, [
        (start: 0.0, end: 60.0),
        (start: 120.0, end: 180.0),
      ]);

      final controller = player.video!;
      for (var i = 1; i <= 10; i++) {
        controller.value = controller.value.copyWith(
          position: Duration(seconds: 10 + i),
          isPlaying: true,
        );
        expect(identical(player.state.bufferedRanges, initialRanges), isTrue);
        expect(identical(session.state, player.state), isTrue);
      }

      // Appending sent danmaku inserts in sorted order without re-sorting from scratch.
      final initialDanmaku = session.danmaku;
      expect(initialDanmaku, hasLength(1));
      session.addSentDanmaku(
        NativeDanmaku(
          id: '501',
          text: 'early',
          mode: 'rolling',
          time: 2,
          size: 24,
          color: const Color(0xFFFFFFFF),
        ),
      );
      session.addSentDanmaku(
        NativeDanmaku(
          id: '502',
          text: 'late',
          mode: 'top',
          time: 25,
          size: 24,
          color: NativeDanmaku.parseColor('#74D9FF'),
        ),
      );
      expect(session.danmaku.map((e) => e.id), ['501', '1', '502']);
    },
  );

  test(
    'StableDanmakuLanes fast-path expiry and NativeDanmaku hex/digit validation preserve all invariants',
    () {
      final lanes = StableDanmakuLanes();
      lanes.prepare(position: 0, laneCount: 2);
      expect(lanes.assign(id: '1', mode: 'rolling', start: 0, end: 10), 0);
      expect(lanes.assign(id: '2', mode: 'rolling', start: 0, end: 10), 1);
      expect(lanes.assign(id: '3', mode: 'rolling', start: 0, end: 10), isNull);

      // Steady frames before expiry keep lane decisions intact.
      for (var frame = 1; frame <= 60; frame++) {
        lanes.prepare(position: frame / 60, laneCount: 2);
        expect(lanes.assign(id: '1', mode: 'rolling', start: 0, end: 10), 0);
        expect(lanes.assign(id: '2', mode: 'rolling', start: 0, end: 10), 1);
      }
      expect(lanes.decisionCount, 3);

      // Explicit clear with unchanged laneCount frees all lanes immediately.
      lanes.clear();
      lanes.prepare(position: 2, laneCount: 2);
      expect(lanes.assign(id: '4', mode: 'rolling', start: 2, end: 12), 0);

      expect(NativeDanmaku.parseColor('#FFFFFF'), const Color(0xFFFFFFFF));
      expect(NativeDanmaku.parseColor('#1a2B3c'), const Color(0xFF1A2B3C));
      for (final invalid in ['', '#FFF', '#12345G', 'FFFFFF']) {
        expect(
          () => NativeDanmaku.parseColor(invalid),
          throwsFormatException,
        );
      }
      expect(
        () => NativeDanmaku(
          id: '12a',
          text: 'bad',
          mode: 'rolling',
          time: 1,
          size: 24,
          color: const Color(0xFFFFFFFF),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'AppStore coalesces rapid setDanmakuSettings disk writes during slider drags',
    () async {
      final storage = _CountingStorage();
      final store = AppStore(
        storage: storage,
        dictionaries: const {},
        folding: SearchFolding({}),
        scripts: const {},
        animeSearch: FakeSearch(),
        metadataApi: FakeMetadata(),
      );
      addTearDown(store.dispose);

      storage.holdWrite = Completer<void>();
      final futures = <Future<void>>[];
      for (var i = 1; i <= 30; i++) {
        futures.add(
          store.setDanmakuSettings(
            DanmakuSettings(opacity: 0.1 + i * 0.02, scale: 1.1),
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(storage.danmakuWrites, 1);

      final firstHold = storage.holdWrite!;
      storage.holdWrite = null;
      firstHold.complete();
      await Future.wait(futures);

      // 30 rapid slider updates coalesce into 2 storage writes (initial + latest).
      expect(storage.danmakuWrites, 2);
      expect(store.danmakuSettings.opacity, closeTo(0.7, 1e-6));
    },
  );

  testWidgets(
    'PlayerPage isolates 60Hz scrubbing, danmaku toggles, and DanmakuPanel from redundant rebuilds',
    (tester) async {
      final video = FakeVideo();
      VideoPlayerPlatform.instance = video;
      final fixture = HttpFixture(ads: false);
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final store = (await tester.runAsync(
        () => AppStore.create(
          nativeHttpApiFactory: fixture.api,
          metadataApi: FakeMetadata(),
          storage: MemoryStorage(),
          animeSearch: FakeSearch(),
        ),
      ))!;
      addTearDown(() async {
        await tester.runAsync(store.closeBrowser);
        store.dispose();
      });

      await tester.runAsync(
        () => store.play(
          const Anime(
            id: '10',
            title: 'Scrub Opt Show',
            cover: '',
            latestVideoId: '40190',
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.runAsync(store.nativeHttpPlayback!.consent);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      store.playerDetail = AnimeDetail.fromJson({
        'title': 'Scrub Opt Show',
        'description': 'Synopsis text ' * 25,
        'episodes': [
          {'id': '40190', 'label': '1'},
          {'id': '40191', 'label': '2'},
        ],
        'metadata': [
          {'label': 'Studio', 'value': 'Test Studio'},
        ],
      });

      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MaterialApp(home: NativeHttpPlayer(store: store)),
        ),
      );
      await tester.pump();

      final controlsFinder = find.byKey(const ValueKey('video-glass-controls'));
      final sliderFinder = find.byKey(const ValueKey('player-progress-slider'));
      final synopsisFinder = find.byType(SynopsisSection);
      final commentsFinder = find.byType(CompactCommentsPreview);
      final surfaceFinder = find.byType(NativeVideoSurface);

      final synopsisBefore = tester.widget(synopsisFinder);
      final commentsBefore = tester.widget(commentsFinder);
      final surfaceBefore = tester.widget(surfaceFinder);

      // Unrelated store updates (fullscreen/lock/danmaku) keep companion details identical,
      // and lock/detail updates keep NativeVideoSurface identical.
      store.favorites = [
        const Anime(id: '99', title: 'Other', cover: ''),
      ];
      // Trigger a store notification via skipOpLongPress toggle.
      await tester.runAsync(() => store.setSkipOpLongPress(false));
      await tester.pump();
      expect(identical(tester.widget(synopsisFinder), synopsisBefore), isTrue);
      expect(identical(tester.widget(commentsFinder), commentsBefore), isTrue);
      expect(identical(tester.widget(surfaceFinder), surfaceBefore), isTrue);

      // Drag the progress slider across 15 steps: after gesture start,
      // GlassContainer and companion widgets must not rebuild on move updates.
      final sliderRect = tester.getRect(sliderFinder);
      final drag = await tester.startGesture(
        sliderRect.centerLeft + const Offset(20, 0),
      );
      await drag.moveBy(const Offset(24, 0));
      await tester.pump();
      final controlsDuringDrag = tester.widget(controlsFinder);
      for (var step = 1; step <= 15; step++) {
        await drag.moveBy(const Offset(10, 0));
        await tester.pump();
        expect(
          identical(tester.widget(controlsFinder), controlsDuringDrag),
          isTrue,
        );
        expect(
          identical(tester.widget(synopsisFinder), synopsisBefore),
          isTrue,
        );
      }
      await drag.up();
      await tester.pump();

      // Mount DanmakuPanel (composer) and push 10 playback position ticks:
      // GlassScaffold inside DanmakuPanel must not rebuild on routine ticks.
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MaterialApp(
            home: DanmakuPanel(store: store, composerOnly: true),
          ),
        ),
      );
      await tester.pump();
      final composerFinder = find.byKey(const ValueKey('danmaku-composer'));
      final composerBefore = tester.widget(composerFinder);
      final controller = store.nativeHttpPlayback!.player!.video!;
      for (var i = 1; i <= 10; i++) {
        controller.value = controller.value.copyWith(
          position: Duration(seconds: 100 + i),
          isPlaying: true,
        );
      }
      await tester.pump();
      expect(identical(tester.widget(composerFinder), composerBefore), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _CountingStorage implements DeviceStorage {
  final _memory = MemoryStorage();
  int danmakuWrites = 0;
  Completer<void>? holdWrite;

  @override
  Future<String?> read(String key) => _memory.read(key);

  @override
  Future<void> write(String key, String value) async {
    if (key == 'baha.device.danmaku') {
      danmakuWrites++;
      if (holdWrite != null) await holdWrite!.future;
    }
    await _memory.write(key, value);
  }

  @override
  Future<void> clearAccountData() => _memory.clearAccountData();
}
