import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/core/search_folding.dart';
import 'package:baha_plus/data/app_diagnostics.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_http_playback.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/data/playback_environment.dart';
import 'package:baha_plus/ui/glass_settings_menu.dart';
import 'package:baha_plus/ui/native_http_player.dart';
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
      expect(identical(seasonal1, store.seasonal), isTrue);
      expect(identical(popular1, store.popular), isTrue);
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
}
