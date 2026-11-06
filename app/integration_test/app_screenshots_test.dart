import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart' as application;
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/official_browser.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real home, library, player and official danmaku display without sending',
    (tester) async {
      Future<void> waitFor(bool Function() ready, {int seconds = 50}) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 150));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue);
      }

      Future<void> waitForImage(Finder parent) => waitFor(
        () => find
            .descendant(of: parent, matching: find.byType(RawImage))
            .evaluate()
            .any((element) => (element.widget as RawImage).image != null),
      );

      final output = Directory(
        '${Directory.systemTemp.path}/baha-app-acceptance',
      )..createSync(recursive: true);
      Future<void> screenshot(String name) async {
        await tester.pump(const Duration(milliseconds: 1800));
        const run = String.fromEnvironment(
          'BAHA_SCREENSHOT_RUN',
          defaultValue: 'manual',
        );
        debugPrint('BAHA_SCREENSHOT_READY:$run:$name');
        // A host-side ADB capture includes platform-view video surfaces.
        // Android's integration-test capture can stall with these surfaces.
        await Future<void>.delayed(const Duration(seconds: 4));
      }

      await application.main();
      await waitFor(() => find.byType(AppRoot).evaluate().isNotEmpty);
      final store = tester.widget<AppRoot>(find.byType(AppRoot)).store;
      await waitFor(() => store.catalog.items.isNotEmpty && !store.busy);
      final carousel = find.byKey(const ValueKey('home-featured-carousel'));
      await waitForImage(carousel);
      await screenshot('home');
      debugPrint('Captured the real home with decoded official artwork.');

      store.selectTab(2, filter: 'all');
      await tester.pump(const Duration(milliseconds: 700));
      await waitForImage(find.byType(AnimeTile).first);
      await screenshot('library');
      debugPrint('Captured the real library with decoded official posters.');

      final target = await store.community('notification-target', {
        'videoId': '45916',
      });
      final anime = Anime.fromJson(target['anime'] as Json);
      await store.openDetail(anime);
      await waitFor(() => !store.detailLoading);
      expect(store.detailFailed, isFalse);
      final episode = store.detail!.episodes.firstWhere(
        (episode) => episode.id == '45916',
      );
      final originalDanmaku = store.danmakuSettings;
      addTearDown(() => store.setDanmakuSettings(originalDanmaku));
      await store.setDanmakuSettings(const DanmakuSettings());
      await store.play(anime, episode: episode);
      await tester.pump(const Duration(milliseconds: 700));
      final portal =
          tester.state(find.byType(OfficialBrowser, skipOffstage: false))
              as OfficialPortal;
      final playbackEnd = DateTime.now().add(const Duration(minutes: 3));
      PlaybackPhase? previous;
      var confirmedAge = false;
      while (!store.playback.value.canControl &&
          DateTime.now().isBefore(playbackEnd)) {
        final state = store.playback.value;
        if (previous != state.phase) {
          debugPrint('Official playback phase: ${state.phase.name}');
          previous = state.phase;
        }
        if (state.phase == PlaybackPhase.age && !confirmedAge) {
          // Click the official visible confirmation UI; never modify its state.
          await portal.evaluate('''
(() => {
  const buttons = [...document.querySelectorAll('#video-container .ncc-choose-btn button')];
  const agree = buttons.find(button => /同意/.test(button.textContent) &&
    !/不同意/.test(button.textContent) && button.getBoundingClientRect().height > 0);
  if (agree) agree.click();
})(); true;
''');
          confirmedAge = true;
        }
        if (state.canOperate && state.paused) await store.controlPlayer('play');
        await tester.pump(const Duration(milliseconds: 250));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(store.playback.value.canControl, isTrue);
      final danmakuButton = find.byKey(const ValueKey('player-danmaku-button'));
      final surface = find
          .ancestor(of: danmakuButton, matching: find.byType(AspectRatio))
          .first;
      expect(
        tester.getRect(surface).contains(tester.getCenter(danmakuButton)),
        isTrue,
      );
      await tester.tap(danmakuButton);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byKey(const ValueKey('danmaku-panel')), findsOneWidget);
      Navigator.pop(
        tester.element(find.byKey(const ValueKey('danmaku-panel'))),
      );
      await tester.pump(const Duration(milliseconds: 700));

      Future<Json> display() async {
        final raw = await portal.evaluate('''
(() => {
  const root = document.querySelector('#video-container');
  const player = root?.querySelector('#ani_video,video-js,.video-js')?.player;
  const controls = player?.usingPlugin?.('animePlayer') ? player.animePlayer() : null;
  const media = root?.querySelector('video');
  const layer = root?.querySelector('.vjs-danmu');
  const bounds = layer?.getBoundingClientRect();
  const times = Object.keys(controls?.danmuManager?.danmuList || {})
    .map(Number).filter(value => value >= 1000 && value < (media?.duration || 0) * 1000 - 5000)
    .sort((a, b) => a - b);
  const visible = [...(layer?.querySelectorAll('.danmu') || [])].filter(node => {
    const rect = node.getBoundingClientRect();
    const style = getComputedStyle(node);
    return bounds && getComputedStyle(layer).display !== 'none' &&
      style.visibility !== 'hidden' && Number(style.opacity) > 0 &&
      node.textContent.trim() && rect.width > 0 && rect.height > 0 &&
      Math.min(rect.right, bounds.right) - Math.max(rect.left, bounds.left) >=
        Math.min(rect.width * .75, bounds.width * .5) &&
      rect.bottom > bounds.top && rect.top < bounds.bottom;
  });
  return JSON.stringify({
    hasLayer: !!layer, visible: visible.length,
    firstTime: times.length ? times[0] / 1000 : null,
    videoWidth: media?.videoWidth || 0, readyState: media?.readyState || 0
  });
})();
''');
        return jsonDecode(raw as String) as Json;
      }

      Json current = await display();
      final danmakuEnd = DateTime.now().add(const Duration(seconds: 40));
      while (current['firstTime'] == null &&
          DateTime.now().isBefore(danmakuEnd)) {
        await tester.pump(const Duration(milliseconds: 300));
        current = await display();
      }
      expect(current['hasLayer'], isTrue);
      expect(current['firstTime'], isNotNull);
      final position = math.max(
        0.0,
        (current['firstTime'] as num).toDouble() - 1,
      );
      Future<void> waitForVisibleDanmaku() async {
        await store.controlPlayer('seek', position);
        await store.controlPlayer('play');
        final end = DateTime.now().add(const Duration(seconds: 20));
        do {
          await tester.pump(const Duration(milliseconds: 200));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          current = await display();
        } while ((current['visible'] as int) == 0 &&
            DateTime.now().isBefore(end));
        expect(current['visible'] as int, greaterThan(0));
        expect(current['videoWidth'] as int, greaterThan(0));
      }

      await waitForVisibleDanmaku();
      final visibleCount = current['visible'];
      await store.controlPlayer('pause');
      await screenshot(
        'danmaku-proof',
      ); // Local verification only; never put user text in README.
      await store.setDanmakuSettings(
        store.danmakuSettings.copyWith(enabled: false),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect((await display())['visible'], 0);
      await store.setDanmakuSettings(
        store.danmakuSettings.copyWith(enabled: true),
      );
      await waitForVisibleDanmaku();
      await store.controlPlayer('pause');
      // The public README shows the player with danmaku hidden for privacy.
      await store.setDanmakuSettings(
        store.danmakuSettings.copyWith(enabled: false),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await screenshot('player');
      await File('${output.path}/result.json').writeAsString(
        jsonEncode({
          'homeArtworkDecoded': true,
          'libraryPostersDecoded': true,
          'videoId': '45916',
          'playbackPhase': store.playback.value.phase.name,
          'danmakuVisibleCount': visibleCount,
          'danmakuOffHidesText': true,
          'danmakuOnRestoresText': true,
          'danmakuButtonInsideVideo': true,
          'publishedContent': false,
        }),
      );
      expect(tester.takeException(), isNull);
      debugPrint(
        'Verified real danmaku text on the video, off/on controls and actual content frames.',
      );
    },
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
