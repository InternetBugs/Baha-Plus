import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'core_test.dart' show MemoryStorage, FakePortal;

void main() {
  Future<void> frames(WidgetTester tester) async {
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<AppStore> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(
      () => AppStore.create(storage: MemoryStorage()),
    ))!;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: BahaPlusApp(store: store, mountPortal: false),
      ),
    );
    await frames(tester);
    return store;
  }

  testWidgets('a fresh home shows navigation but no catalog filler', (
    tester,
  ) async {
    final store = await launch(tester);
    expect(find.text(store.t('explore')), findsWidgets);
    expect(find.text(store.t('seasonal')), findsNothing);
    expect(find.text(store.t('popular')), findsNothing);
    expect(find.text(store.t('dataSnapshot')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search, language and appearance use the real shared interface', (
    tester,
  ) async {
    final store = await launch(tester);
    store.selectTab(3);
    await frames(tester);
    expect(find.text('為你推薦'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'BahaNoMatch');
    await frames(tester);
    expect(find.text('還沒找到這部作品'), findsOneWidget);
    await store.setLanguage('zh-Hans');
    await store.setAppearance('dark');
    await frames(tester);
    expect(find.text('还没找到这部作品'), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(EditableText))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.bySemanticsLabel('清除搜索'));
    await frames(tester);
    expect(find.text('为你推荐'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android and iOS use the same header and floating glass tabs', (
    tester,
  ) async {
    final geometry = <TargetPlatform, List<Rect>>{};
    try {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        await launch(tester);
        geometry[platform] = [
          tester.getRect(
            find.descendant(
              of: find.byType(GlassLargeTitle),
              matching: find.text('探索'),
            ),
          ),
          tester.getRect(find.byType(GlassTabBar)),
          tester.getRect(find.byType(AccountAvatar).hitTestable()),
        ];
        await tester.pumpWidget(const SizedBox.shrink());
        await frames(tester);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(geometry[TargetPlatform.android], geometry[TargetPlatform.iOS]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account opens as the same rounded large glass sheet', (
    tester,
  ) async {
    final store = await launch(tester);
    await tester.tap(find.byType(AccountAvatar).hitTestable());
    await frames(tester);
    expect(find.text(store.t('officialAccount')), findsOneWidget);
    expect(find.text(store.t('localProfile')), findsOneWidget);
    expect(find.text(store.t('syncAccount')), findsNWidgets(2));
    expect(find.byType(GlassModalSheet), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(store.t('close')));
    await frames(tester);
    expect(find.byType(GlassModalSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the entire playback page is native and controls follow the current official episode',
    (tester) async {
      final store = await launch(tester);
      final portal = FakePortal();
      await store.attach(portal);
      const anime = Anime(
        id: '10',
        title: 'Test Anime',
        cover: 'https://p2.bahamut.com.tw/10.jpg',
        latestVideoId: '20',
      );
      await store.play(anime);
      store.playerDetail = AnimeDetail.fromJson({
        'title': 'Test Anime',
        'description': 'Synopsis',
        'episodes': [
          {'id': '20', 'label': '1'},
          {'id': '21', 'label': '2'},
        ],
        'metadata': [
          {'label': 'Studio', 'value': 'Test'},
        ],
      });
      Navigator.of(tester.element(find.byType(AppRoot))).push(
        CupertinoPageRoute<void>(
          builder: (_) => PlayerPage(
            store: store,
            video: const ColoredBox(
              key: ValueKey('test-video-surface'),
              color: Colors.black,
            ),
          ),
        ),
      );
      await frames(tester);
      Future<void> state(String phase) => store.receive(
        jsonEncode({
          'type': 'player-state',
          'requestId': store.operation.id,
          'id': '10',
          'videoId': '20',
          'phase': phase,
          'surfaceReady': true,
          'paused': false,
          'buffering': false,
          'ended': false,
          'muted': false,
          'position': 37,
          'duration': 1200,
          'buffered': 90,
          'rate': 1,
        }),
        origin: OfficialSite.home,
        source: OfficialSite.video('20'),
        isMainFrame: true,
      );
      await state('content');
      await frames(tester);
      expect(find.text(store.t('nowPlaying')), findsOneWidget);
      expect(find.text(store.t('episodes')), findsOneWidget);
      expect(find.text('Test Anime'), findsOneWidget);
      final video = tester.getRect(
        find.byKey(const ValueKey('test-video-surface')),
      );
      expect(video.width / video.height, closeTo(16 / 9, .001));
      await tester.tap(find.bySemanticsLabel(store.t('pausePlayback')));
      expect(portal.scripts.last, contains('"pause"'));
      await state('advertisement');
      await frames(tester);
      final before = portal.scripts.length;
      await tester.tap(find.bySemanticsLabel(store.t('forwardTen')));
      expect(portal.scripts.length, before);
      final controlBar = tester.getRect(
        find.byKey(const ValueKey('video-glass-controls')),
      );
      expect(video.contains(controlBar.topLeft), isTrue);
      expect(video.contains(controlBar.bottomRight), isTrue);
      await state('error');
      await frames(tester);
      expect(find.byKey(const ValueKey('video-glass-controls')), findsNothing);
      expect(find.text(store.t('playerPlaybackError')), findsOneWidget);
      expect(find.text(store.t('retry')), findsOneWidget);
      await state('advertisement');
      await frames(tester);
      await tester.tap(find.bySemanticsLabel(store.t('fullScreen')));
      await frames(tester);
      expect(store.playerFullscreen, isTrue);
      expect(find.byKey(const ValueKey('test-video-surface')), findsOneWidget);
      await store.dismissBrowser();
      await frames(tester);
      expect(store.playerFullscreen, isFalse);
      expect(store.browserVisible, isTrue);
      await tester.tap(find.text('2'));
      await frames(tester);
      expect(portal.visited.last, OfficialSite.video('21'));
      expect(store.playerDetail!.episodes.length, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
