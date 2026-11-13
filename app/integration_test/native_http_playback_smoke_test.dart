import 'dart:convert';
import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/native_http_playback.dart';
import 'package:baha_plus/main.dart' as application;
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/official_browser.dart';
import 'package:baha_plus/ui/native_video_surface.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'guest HTTP authorization, real ad and native content without WebView',
    (tester) async {
      Future<void> waitFor(
        bool Function() condition, {
        Duration timeout = const Duration(seconds: 60),
        NativeHttpPlayback? session,
      }) async {
        final elapsed = Stopwatch()..start();
        while (!condition() && elapsed.elapsed < timeout) {
          if (session?.failureStage != null) {
            fail(
              'HTTP stage: ${session!.failureStage}, code: ${session.failureCode}',
            );
          }
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue, reason: 'Timed out after $timeout');
        await tester.pump(const Duration(milliseconds: 100));
      }

      void noWebView() {
        expect(find.byType(OfficialBrowser, skipOffstage: false), findsNothing);
        expect(find.byType(InAppWebView, skipOffstage: false), findsNothing);
      }

      await application.main();
      await waitFor(() => find.byType(AppRoot).evaluate().isNotEmpty);
      final store = tester.widget<AppRoot>(find.byType(AppRoot)).store;
      expect(store.enableNativeHttpPlayback, isTrue);
      await waitFor(() => !store.updates.checking);
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byType(CupertinoAlertDialog).evaluate().isNotEmpty) {
        await tester.tap(find.text(store.t('updateLater')));
        await tester.pump(const Duration(milliseconds: 500));
      }
      const videoId = String.fromEnvironment(
        'BAHA_HTTP_TEST_VIDEO',
        defaultValue: '40190',
      );
      final video = await tester.runAsync(
        () => store.metadataApi.fetchVideo(videoId),
      );
      await store.play(
        Anime(
          id: video!.animeId,
          title: video.title,
          cover: '',
          latestVideoId: videoId,
        ),
      );
      final session = store.nativeHttpPlayback!;
      await waitFor(() => session.needsConsent, session: session);
      noWebView();
      expect(store.needsOfficialPortal, isFalse);
      await tester.tap(find.byKey(const ValueKey('http-playback-consent')));
      await waitFor(
        () =>
            session.state.phase == PlaybackPhase.advertisement &&
            session.state.position > 1,
        session: session,
      );
      expect(session.canSkipAd, isFalse);
      final adVideo = session.player!.video!;
      expect(adVideo.value.size.width, greaterThan(1));
      await store.controlPlayer('pause');
      final adWatchPaused = session.adWatch.total;
      await tester.pump(const Duration(milliseconds: 900));
      expect(session.adWatch.total, closeTo(adWatchPaused, .1));
      await store.controlPlayer('play');
      await waitFor(
        () => session.canSkipAd || session.state.phase == PlaybackPhase.content,
        timeout: const Duration(minutes: 3),
        session: session,
      );
      noWebView();
      final adSeconds = session.adWatch.total;
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('native-http-advertisement');
      if (session.canSkipAd) {
        await tester.tap(find.byKey(const ValueKey('http-skip-ad')));
      }
      await waitFor(
        () =>
            store.playback.value.canControl &&
            !store.playback.value.buffering &&
            session.player!.video!.value.size.width > 1,
        session: session,
      );
      noWebView();
      final originalDanmaku = store.danmakuSettings;
      addTearDown(() => store.setDanmakuSettings(originalDanmaku));
      await store.setDanmakuSettings(const DanmakuSettings());
      await waitFor(() => !session.danmakuLoading, session: session);
      expect(session.danmakuFailureStage, isNull);
      expect(session.danmaku, isNotEmpty);
      expect(session.state.hasDanmaku, isTrue);
      final item = session.danmaku.firstWhere(
        (item) => item.time + 2 < session.state.duration,
      );
      await store.controlPlayer('pause');
      await store.controlPlayer('seek', item.time + 1);
      await tester.pump(const Duration(milliseconds: 200));
      final danmakuSurface = tester.state<NativeVideoSurfaceState>(
        find.byType(NativeVideoSurface),
      );
      final visibleDanmaku = danmakuSurface.cachedTextPainters;
      expect(visibleDanmaku, greaterThan(0));
      await store.setDanmakuSettings(
        store.danmakuSettings.copyWith(enabled: false),
      );
      await tester.pump();
      expect(danmakuSurface.cachedTextPainters, 0);
      await store.setDanmakuSettings(
        store.danmakuSettings.copyWith(enabled: true),
      );
      await tester.pump();
      expect(danmakuSurface.cachedTextPainters, greaterThan(0));
      expect(find.byKey(const ValueKey('player-danmaku-send')), findsOneWidget);
      noWebView();
      await binding.takeScreenshot('native-http-danmaku');
      await store.controlPlayer('play');
      final contentVideo = session.player!.video!;
      final before = (await contentVideo.position)!;
      await waitFor(
        () => session.state.position > before.inMilliseconds / 1000 + 1,
        session: session,
      );
      await store.controlPlayer('pause');
      final paused = (await contentVideo.position)!;
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        ((await contentVideo.position)! - paused).inMilliseconds.abs(),
        lessThan(350),
      );
      final target = paused.inMilliseconds / 1000 + 10;
      await store.controlPlayer('seek', target);
      expect(
        ((await contentVideo.position)!.inMilliseconds / 1000 - target).abs(),
        lessThan(.6),
      );
      expect(session.state.paused, isTrue);
      if (session.state.qualities.contains(360)) {
        await store.controlPlayer('quality', 360);
        expect(session.state.quality, 360);
      }
      await store.controlPlayer('rate', 1.5);
      expect(session.state.rate, 1.5);
      final playerId = session.player!.video!.playerId;
      await store.controlPlayer('play');
      await waitFor(() => !session.state.paused, session: session);
      await store.setApplicationActive(false);
      final background = session.state.position;
      await tester.pump(const Duration(milliseconds: 900));
      expect(session.state.paused, isTrue);
      await store.setApplicationActive(true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.state.paused, isTrue);
      expect(session.state.position, closeTo(background, .35));
      expect(session.player!.video!.playerId, playerId);
      await store.controlPlayer('play');
      await waitFor(
        () =>
            session.watch.total >= 61 && session.acceptedPeriodicProgress >= 1,
        timeout: const Duration(minutes: 2),
        session: session,
      );
      await store.controlPlayer('pause');
      await tester.pump(const Duration(milliseconds: 200));
      await binding.takeScreenshot('native-http-content');
      final report = <String, Object?>{
        'videoId': videoId,
        'guestSession': true,
        'realAdMediaSeconds': adSeconds,
        'watchMediaSeconds': session.watch.total,
        'acceptedGuestProgress': session.acceptedProgress,
        'acceptedPeriodicGuestProgress': session.acceptedPeriodicProgress,
        'contentWidth': session.player!.video!.value.size.width,
        'contentHeight': session.player!.video!.value.size.height,
        'quality': session.state.quality,
        'rate': session.state.rate,
        'pausedAfterForeground': true,
        'noWebView': true,
        'nativeDanmakuCount': session.danmaku.length,
        'visibleNativeDanmaku': visibleDanmaku,
        'danmakuToggleVerified': true,
        'nativePlayerPreservedOnForeground': true,
      };
      binding.reportData = report;
      debugPrint('BAHA_NATIVE_HTTP ${jsonEncode(report)}');
      if (const bool.fromEnvironment('BAHA_HTTP_INSPECTION')) {
        await store.controlPlayer('play');
        await waitFor(() => !session.state.paused, session: session);
        final inspectedPlayerId = session.player!.video!.playerId;
        debugPrint('BAHA_NATIVE_HTTP_INSPECTION_READY');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 30)),
        );
        expect(session.state.paused, isTrue);
        expect(session.player!.video!.playerId, inspectedPlayerId);
        noWebView();
      }
      await store.closeBrowser();
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.player, isNull);
      noWebView();
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
