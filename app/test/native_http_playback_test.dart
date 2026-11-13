import 'dart:async';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/core/search_folding.dart';
import 'package:baha_plus/data/app_diagnostics.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/app_updates.dart';
import 'package:baha_plus/data/native_http_playback.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/native_http_player.dart';
import 'package:baha_plus/ui/native_video_surface.dart';
import 'package:baha_plus/ui/danmaku_panel.dart';
import 'package:baha_plus/ui/official_browser.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'core_test.dart' show MemoryStorage, FakeSearch, FakePortal;
import 'fake_metadata.dart';
import 'native_http_api_test.dart' show HttpFixture;
import 'native_playback_test.dart' show FakeVideo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeVideo video;
  setUp(() {
    video = FakeVideo();
    VideoPlayerPlatform.instance = video;
  });

  test(
    'real ad advancement gates source and ad controls cannot seek',
    () async {
      final fixture = HttpFixture();
      var now = Duration.zero;
      final session = NativeHttpPlayback(
        document: 'ad',
        videoId: '40190',
        preferredQuality: 360,
        diagnostics: AppDiagnostics.instance,
        api: fixture.api(),
        now: () => now,
        onState: (_) {},
      );
      addTearDown(session.close);
      await session.prepare();
      expect(session.needsConsent, isTrue);
      expect(fixture.count('video_src.php'), 0);
      await session.consent();
      expect(session.state.phase, PlaybackPhase.advertisement);
      expect(session.state.hasDanmaku, isFalse);
      expect(session.danmaku, isEmpty);
      expect(fixture.count('danmu.php'), 0);
      expect(await session.command('seek', 100), isFalse);
      expect(await session.command('rate', 2), isFalse);
      expect(await session.command('quality', 360), isFalse);
      void advance(int seconds) {
        now = Duration(seconds: seconds);
        final player = session.player!.video!;
        player.value = player.value.copyWith(
          position: Duration(seconds: seconds),
          isPlaying: true,
        );
      }

      for (var second = 1; second < 30; second++) {
        advance(second);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.canSkipAd, isFalse);
      await session.skipAd();
      expect(fixture.count('video_src.php'), 0);
      advance(30);
      expect(session.canSkipAd, isTrue);
      await session.skipAd();
      expect(session.state.phase, PlaybackPhase.content);
      expect(session.state.hasDanmaku, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.danmaku.single.text, 'Test & native');
      expect(fixture.count('danmu.php'), 1);
      expect(fixture.count('video_src.php'), 1);
      expect(video.sources.last.uri, endsWith('/content/360.m3u8'));
      await session.close();
      expect(video.released.length, 2);
    },
  );

  test(
    'periodic progress is acknowledged after 60 real media seconds',
    () async {
      final fixture = HttpFixture(ads: false);
      var now = Duration.zero;
      final session = NativeHttpPlayback(
        document: 'periodic',
        videoId: '40190',
        preferredQuality: 0,
        diagnostics: AppDiagnostics.instance,
        api: fixture.api(),
        now: () => now,
        onState: (_) {},
      );
      addTearDown(session.close);
      await session.prepare();
      await session.consent();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.acceptedPeriodicProgress, 0);
      final controller = session.player!.video!;
      for (var second = 1; second <= 61; second++) {
        now = Duration(seconds: second);
        final position = Duration(seconds: 10 + second);
        video.positions[controller.playerId] = position;
        controller.value = controller.value.copyWith(
          position: position,
          isPlaying: true,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.watch.total, 61);
      expect(session.acceptedPeriodicProgress, 1);
      expect(fixture.progressCount, 2);
      await session.close();
    },
  );

  test(
    'native EOF flushes a complete ad but rejects a genuinely short ad',
    () async {
      for (final duration in [15.0, 30.03]) {
        final fixture = HttpFixture();
        final session = NativeHttpPlayback(
          document: 'eof-$duration',
          videoId: '40190',
          preferredQuality: 0,
          diagnostics: AppDiagnostics.instance,
          api: fixture.api(),
          onState: (_) {},
        );
        await session.prepare();
        await session.consent();
        final controller = session.player!.video!;
        controller.value = controller.value.copyWith(
          position: const Duration(milliseconds: 100),
          isPlaying: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        controller.value = controller.value.copyWith(
          duration: Duration(milliseconds: (duration * 1000).round()),
          position: Duration(milliseconds: (duration * 1000).round() - 43),
          isPlaying: false,
          isCompleted: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        if (duration < 30) {
          expect(session.failureStage, 'short-ad-needs-fallback');
          expect(fixture.count('video_src.php'), 0);
        } else {
          expect(session.state.phase, PlaybackPhase.content);
          expect(session.adWatch.total, duration);
          expect(fixture.count('video_src.php'), 1);
        }
        await session.close();
      }
    },
  );

  test('background during creation never starts decoder on return', () async {
    final fixture = HttpFixture(ads: false);
    final session = NativeHttpPlayback(
      document: 'lifecycle',
      videoId: '40190',
      preferredQuality: 0,
      diagnostics: AppDiagnostics.instance,
      api: fixture.api(),
      onState: (_) {},
    );
    addTearDown(session.close);
    await session.prepare();
    video.holdCreation = Completer<void>();
    final opening = session.consent();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(video.sources, isEmpty);
    final pausing = session.setApplicationActive(false);
    video.holdCreation!.complete();
    await opening.timeout(const Duration(seconds: 3));
    await pausing.timeout(const Duration(seconds: 3));
    expect(session.state.paused, isTrue);
    expect(video.playCalls, isEmpty);
    await session.setApplicationActive(true);
    expect(video.playCalls, isEmpty);
    expect(await session.command('play', null), isTrue);
    expect(video.playCalls.length, 1);
    await session.close();
  });

  test('episode retirement rejects late source and decoder creation', () async {
    final fixture = HttpFixture(ads: false);
    final session = NativeHttpPlayback(
      document: 'retired',
      videoId: '40190',
      preferredQuality: 0,
      diagnostics: AppDiagnostics.instance,
      api: fixture.api(),
      onState: (_) {},
    );
    addTearDown(session.close);
    await session.prepare();
    video.holdCreation = Completer<void>();
    final opening = session.consent();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    session.dispose();
    video.holdCreation!.complete();
    await opening;
    await session.released;
    expect(video.playCalls, isEmpty);
    expect(video.released.length, 1);
  });

  test(
    'danmaku errors are independent of playback and can be retried',
    () async {
      final fixture = HttpFixture(ads: false);
      fixture.handler = (request) async =>
          request.url.path.endsWith('/danmu.php')
          ? http.Response('{"error":{"code":503}}', 200)
          : fixture.response(request);
      final session = NativeHttpPlayback(
        document: 'danmaku-error',
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
      final player = session.player;
      expect(session.danmakuFailureStage, 'danmaku');
      expect(session.failureStage, isNull);
      expect(session.state.canControl, isTrue);
      fixture.handler = null;
      await session.loadDanmaku();
      expect(session.danmakuFailureStage, isNull);
      expect(session.danmaku.single.id, '1');
      expect(session.player, same(player));
      expect(fixture.count('video_src.php'), 1);
    },
  );

  test('late danmaku is ignored after episode retirement', () async {
    final fixture = HttpFixture(ads: false);
    final response = Completer<http.Response>();
    fixture.handler = (request) async => request.url.path.endsWith('/danmu.php')
        ? response.future
        : fixture.response(request);
    var notifications = 0;
    final session = NativeHttpPlayback(
      document: 'danmaku-retired',
      videoId: '40190',
      preferredQuality: 0,
      diagnostics: AppDiagnostics.instance,
      api: fixture.api(),
      onState: (_) {},
    )..addListener(() => notifications++);
    await session.prepare();
    await session.consent();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final loading = session.loadDanmaku();
    expect(fixture.count('danmu.php'), 1);
    expect(session.danmakuLoading, isTrue);
    session.dispose();
    final retiredNotifications = notifications;
    response.complete(
      http.Response(
        '{"data":{"danmu":[{"sn":99,"time":0,"text":"old"}]}}',
        200,
      ),
    );
    await loading;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await session.released;
    expect(session.danmaku, isEmpty);
    expect(notifications, retiredNotifications);
  });

  testWidgets('integrated HTTP player mounts no portal and routes controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = HttpFixture(ads: false);
    final store = AppStore(
      storage: MemoryStorage(),
      dictionaries: const {},
      folding: SearchFolding({}),
      scripts: const {},
      animeSearch: FakeSearch(),
      metadataApi: FakeMetadata(),
      updates: AppUpdates(
        versionLoader: () async => '1.0.0',
        client: MockClient((_) async => http.Response('', 404)),
      ),
      enableNativeHttpPlayback: true,
      nativeHttpApiFactory: fixture.api,
    );
    final portal = FakePortal();
    await store.attach(portal);
    await tester.pumpWidget(BahaPlusApp(store: store));
    const anime = Anime(
      id: '1',
      title: 'Sample',
      cover: '',
      latestVideoId: '40190',
    );
    await tester.runAsync(() => store.play(anime));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.byType(NativeHttpPlayer), findsOneWidget);
    expect(find.byType(OfficialBrowser, skipOffstage: false), findsNothing);
    expect(find.byType(InAppWebView, skipOffstage: false), findsNothing);
    expect(store.needsOfficialPortal, isFalse);
    expect(portal.visited, isEmpty);
    expect(fixture.count('video_src.php'), 0);
    expect(find.byKey(const ValueKey('http-playback-consent')), findsOneWidget);
    await tester.runAsync(store.nativeHttpPlayback!.consent);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.playback.value.phase, PlaybackPhase.content);
    expect(
      tester
          .widget<NativeVideoSurface>(find.byType(NativeVideoSurface))
          .danmaku
          .single
          .text,
      'Test & native',
    );
    expect(find.byKey(const ValueKey('player-danmaku-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-danmaku-send')), findsNothing);
    final currentPlayer = store.nativeHttpPlayback!.player;
    await tester.tap(find.byKey(const ValueKey('player-danmaku-button')));
    await tester.pump();
    expect(
      tester
          .widget<NativeVideoSurface>(find.byType(NativeVideoSurface))
          .settings
          .enabled,
      isFalse,
    );
    await tester.runAsync(
      () => store.setDanmakuSettings(
        const DanmakuSettings(opacity: .5, scale: 1.2, top: false),
      ),
    );
    await tester.pump();
    final surface = tester.widget<NativeVideoSurface>(
      find.byType(NativeVideoSurface),
    );
    expect(surface.settings.opacity, .5);
    expect(surface.settings.top, isFalse);
    expect(store.nativeHttpPlayback!.player, same(currentPlayer));
    await expectLater(
      store.sendDanmaku('test'),
      throwsA(
        isA<CommunityException>().having(
          (error) => error.code,
          'code',
          'login',
        ),
      ),
    );
    expect(portal.scripts, isEmpty);
    expect(portal.communityRequests, isEmpty);
    fixture.handler = (request) async => request.url.path.endsWith('/danmu.php')
        ? http.Response('', 503)
        : fixture.response(request);
    await tester.runAsync(store.nativeHttpPlayback!.loadDanmaku);
    showDanmakuPanel(tester.element(find.byType(NativeHttpPlayer)), store);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('danmakuLoadError'), findsOneWidget);
    fixture.handler = null;
    await tester.tap(find.text('retry'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.text('danmakuLoadError'), findsNothing);
    expect(store.nativeHttpPlayback!.player, same(currentPlayer));
    Navigator.of(tester.element(find.byType(DanmakuPanel))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => store.controlPlayer('pause'));
    expect(store.playback.value.paused, isTrue);
    await tester.runAsync(() => store.controlPlayer('seek', 42));
    expect(video.positions.values.last, const Duration(seconds: 42));
    await tester.runAsync(() => store.setApplicationActive(false));
    await tester.runAsync(() => store.setApplicationActive(true));
    expect(store.playback.value.paused, isTrue);
    await tester.runAsync(() => store.controlPlayer('play'));
    expect(store.playback.value.paused, isFalse);
    expect(portal.scripts, isEmpty);
    expect(store.operation.videoId, '40190');
    await tester.runAsync(
      () => store.play(
        anime,
        episode: const Episode(id: '40191', label: '2'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.operation.videoId, '40191');
    expect(store.nativeHttpPlayback!.danmaku, isEmpty);
    expect(video.released.length, 1);
    await tester.runAsync(store.nativeHttpPlayback!.consent);
    await tester.runAsync(() async {
      final progress = Completer<http.Response>();
      fixture.handler = (request) async =>
          request.url.path == '/ajax/elapse.php'
          ? progress.future
          : fixture.response(request);
      final closing = store.closeBrowser();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        store.needsOfficialPortal,
        isFalse,
        reason: 'HTTP teardown must not retain or mount an official portal',
      );
      progress.complete(http.Response('{"state":"ok"}', 200));
      await closing;
    });
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    expect(tester.takeException(), isNull);
  });
}
