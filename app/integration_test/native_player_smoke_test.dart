import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/main.dart' as application;
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/official_browser.dart';
import 'package:baha_plus/ui/native_video_surface.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'authorized mobile native playback, quality, pause, seek, lifecycle and release',
    (tester) async {
      Future<void> waitFor(bool Function() ready, {int seconds = 60}) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        expect(ready(), isTrue);
      }

      await application.main();
      await waitFor(() => find.byType(AppRoot).evaluate().isNotEmpty);
      final store = tester.widget<AppRoot>(find.byType(AppRoot)).store;
      final backend = defaultTargetPlatform == TargetPlatform.iOS
          ? 'ios-avplayer'
          : 'android-exoplayer';
      await waitFor(() => !store.catalogLoading && !store.updates.checking);
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byType(CupertinoAlertDialog).evaluate().isNotEmpty) {
        await tester.tap(find.text(store.t('updateLater')));
        await tester.pump(const Duration(milliseconds: 500));
      }
      const videoId = String.fromEnvironment(
        'BAHA_NATIVE_TEST_VIDEO',
        defaultValue: '40190',
      );
      final target = await store.community('notification-target', {
        'videoId': videoId,
      });
      final anime = Anime.fromJson(target['anime'] as Json);
      await store.play(
        anime,
        episode: const Episode(id: videoId, label: '1'),
      );
      await waitFor(
        () => find
            .byType(OfficialBrowser, skipOffstage: false)
            .evaluate()
            .isNotEmpty,
      );
      final dynamic portal = tester.state(
        find.byType(OfficialBrowser, skipOffstage: false),
      );
      final end = DateTime.now().add(const Duration(minutes: 4));
      var agreed = false;
      while ((!store.usesNativePlayback || !store.playback.value.canControl) &&
          DateTime.now().isBefore(end)) {
        if (store.playback.value.phase.name == 'age' && !agreed) {
          // Explicitly authorized by the user: click the real official button.
          final selected = await portal.evaluate('''
(() => {
  const button = document.querySelector('.ncc-choosebar button#adult.choose-btn-agree');
  if (!button || button.textContent.trim() !== '同意' || !button.getBoundingClientRect().height) return false;
  button.click(); return true;
})()
''');
          agreed = selected == true;
          if (agreed) {
            debugPrint('[BAHA_NATIVE_TEST] selected official age agreement');
          }
        }
        await tester.pump(const Duration(milliseconds: 150));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(
        store.usesNativePlayback,
        isTrue,
        reason: 'Playback must actually use $backend',
      );
      await waitFor(() => !store.playback.value.buffering);
      expect(find.byType(NativeVideoSurface), findsOneWidget);
      final surface = tester.widget<NativeVideoSurface>(
        find.byType(NativeVideoSurface),
      );
      final controller = surface.playback;
      expect(controller.video!.value.isInitialized, isTrue);
      final web =
          jsonDecode(
                await portal.evaluate('''
JSON.stringify({dom: document.querySelectorAll('*').length,
  source: document.querySelector('#video-container video')?.getAttribute('src') || '',
  iframeCount: document.querySelectorAll('iframe').length,
  backend: window.__bahaPlayerBridge?.diagnostics().backend})
''')
                    as String,
              )
              as Json;
      expect(web['source'], isEmpty);
      expect(web['iframeCount'], 0);
      expect(web['backend'], backend);
      debugPrint(
        '[BAHA_NATIVE_TEST] actual native texture active; remaining DOM=${web['dom']}',
      );
      await store.controlPlayer('play');
      final start = store.playback.value.position;
      await waitFor(() => store.playback.value.position > start + 3);
      await store.controlPlayer('pause');
      final paused = store.playback.value.position;
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.pump();
      expect((store.playback.value.position - paused).abs(), lessThan(.4));
      await store.controlPlayer('seek', 90);
      await waitFor(() => (store.playback.value.position - 90).abs() < 1);
      await store.controlPlayer('rate', 1.5);
      final qualities = [...store.playback.value.qualities];
      for (final quality in [...qualities.take(2), 0]) {
        await store.controlPlayer('quality', quality.toDouble());
        await waitFor(() => store.playback.value.quality == quality);
        expect(store.playback.value.paused, isTrue);
        expect((store.playback.value.position - 90).abs(), lessThan(1));
        expect(store.playback.value.rate, 1.5);
      }
      store.setPlayerFullscreen(true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester
            .widget<NativeVideoSurface>(find.byType(NativeVideoSurface))
            .playback,
        same(controller),
      );
      store.setPlayerFullscreen(false);
      await tester.pump(const Duration(milliseconds: 500));
      await store.controlPlayer('play');
      await store.setApplicationActive(false);
      // Exercise the app observer as well as the store's lifecycle boundary.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await waitFor(() => store.playback.value.paused);
      final background = store.playback.value.position;
      await Future<void>.delayed(const Duration(seconds: 2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await store.setApplicationActive(true);
      await tester.pump();
      expect(store.playback.value.paused, isTrue);
      expect((store.playback.value.position - background).abs(), lessThan(.5));
      debugPrint(
        '[BAHA_NATIVE_TEST] playback controls, listed qualities and lifecycle passed',
      );
      await store.controlPlayer('rate', 1);
      await store.controlPlayer('seek', 0);
      await store.controlPlayer('play');
      const soakSeconds = int.fromEnvironment(
        'BAHA_NATIVE_SOAK_SECONDS',
        defaultValue: 600,
      );
      expect(soakSeconds, greaterThanOrEqualTo(30));
      final soakEnd = DateTime.now().add(Duration(seconds: soakSeconds));
      debugPrint(
        '[BAHA_NATIVE_TEST] soak-start=${DateTime.now().toUtc().toIso8601String()}',
      );
      var previous = -1;
      while (DateTime.now().isBefore(soakEnd)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final state = store.playback.value;
        expect(store.usesNativePlayback, isTrue);
        expect(state.phase.name, isNot('error'));
        final minute = DateTime.now().difference(soakEnd).inSeconds ~/ 30;
        if (minute != previous) {
          previous = minute;
          final renderer = tester.state<NativeVideoSurfaceState>(
            find.byType(NativeVideoSurface),
          );
          expect(renderer.cachedTextPainters, lessThanOrEqualTo(64));
          debugPrint(
            '[BAHA_NATIVE_TEST] soak position=${state.position.toStringAsFixed(1)} '
            'buffering=${state.buffering} textPainters=${renderer.cachedTextPainters}',
          );
        }
      }
      expect(store.playback.value.position, greaterThan(soakSeconds * .8));
      debugPrint(
        '[BAHA_NATIVE_TEST] soak-end=${DateTime.now().toUtc().toIso8601String()}',
      );
      await store.closeBrowser();
      await tester.pump(const Duration(milliseconds: 500));
      expect(store.usesNativePlayback, isFalse);
      expect(find.byType(NativeVideoSurface), findsNothing);
      expect(controller.video, isNull);
      expect(find.byType(OfficialBrowser, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
      binding.reportData = {
        'videoId': videoId,
        'backend': backend,
        'nativeDecoder': true,
        'qualityPauseSeekRate': true,
        'pausedAfterForeground': true,
        'soakSeconds': soakSeconds,
        'releasedPlayerAndWebView': true,
        'realPublications': 0,
      };
      debugPrint('BAHA_NATIVE_PLAYBACK ${jsonEncode(binding.reportData)}');
      debugPrint(
        '[BAHA_NATIVE_TEST] $soakSeconds-second playback and release passed',
      );
    },
    timeout: const Timeout(Duration(minutes: 18)),
  );
}
