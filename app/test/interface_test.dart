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
import 'package:baha_plus/ui/detail_page.dart';
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
    store.selectTab(4);
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

  testWidgets(
    'popular titles form a vertical waterfall and catalog status text is absent',
    (tester) async {
      final store = await launch(tester);
      final titles = List.generate(
        20,
        (index) => index == 1
            ? 'A longer title that wraps across several lines in the waterfall'
            : 'Anime ${index + 1}',
      );
      store.catalog = Catalog(
        fetchedAt: '2026-11-06T00:00:00Z',
        items: [
          for (var index = 0; index < titles.length; index++)
            Anime(
              id: '${index + 1}',
              title: titles[index],
              cover: 'https://p2.bahamut.com.tw/${index + 1}.jpg',
              poster: 'https://p2.bahamut.com.tw/${index + 1}.jpg',
              episodeLabel: '第1集',
              sections: const ['hot'],
            ),
        ],
      );
      store.selectTab(0);
      await frames(tester);
      expect(find.textContaining(store.t('dataCached')), findsNothing);
      expect(find.textContaining(store.t('dataLive')), findsNothing);
      expect(find.byType(ListView), findsNothing);
      final first = tester.getRect(find.byKey(const ValueKey('popular-1')));
      final second = tester.getRect(find.byKey(const ValueKey('popular-2')));
      expect(first.top, second.top);
      expect(first.left, lessThan(second.left));
      expect(first.height, lessThan(second.height));
      final lastTile = find.byKey(const ValueKey('popular-20')).hitTestable();
      for (var step = 0; step < 35 && lastTile.evaluate().isEmpty; step++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
        await frames(tester);
      }
      expect(lastTile, findsOneWidget);
      await tester.tap(lastTile);
      await frames(tester);
      expect(find.byType(DetailPage), findsOneWidget);
      expect(store.selectedAnime?.id, '20');
      // The native portal is disabled in this layout test.
      store.navigationFailed();
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.text(store.t('syncAccount')), findsNothing);
    expect(find.text(store.t('favorites')), findsOneWidget);
    expect(find.text(store.t('manageAccount')), findsNothing);
    expect(find.text(store.t('history')), findsNothing);
    expect(find.byType(GlassModalSheet), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(store.t('close')));
    await frames(tester);
    expect(find.byType(GlassModalSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history tab distinguishes guest and synced empty states and resumes the cloud episode',
    (tester) async {
      final store = await launch(tester);
      store.catalog = const Catalog(
        items: [
          Anime(
            id: '10',
            title: 'Catalog Anime',
            cover: 'https://p2.bahamut.com.tw/10.jpg',
          ),
        ],
      );
      final tabs = find.byType(GlassTabBar);
      expect(tester.widget<GlassTabBar>(tabs).tabs.length, 5);
      await tester.tap(
        find.descendant(of: tabs, matching: find.text(store.t('watchHistory'))),
      );
      await frames(tester);
      expect(store.tab, 3);
      expect(find.text(store.t('historyHint')), findsOneWidget);
      expect(find.text(store.t('connectAccount')), findsOneWidget);
      final portal = FakePortal();
      await store.attach(portal);
      store.updateNavigation(
        OfficialSite.home.resolve('mygather.php'),
        canGoBack: false,
      );
      Future<void> synced(List<Map<String, dynamic>> history) async {
        await store.syncAccount();
        await store.receive(
          jsonEncode({
            'type': 'account-synced',
            'requestId': store.operation.id,
            'favorites': [],
            'history': history,
          }),
          origin: OfficialSite.home,
          source: OfficialSite.home.resolve('mygather.php'),
          isMainFrame: true,
        );
        await frames(tester);
      }

      await synced([]);
      expect(find.text(store.t('noHistory')), findsOneWidget);
      expect(find.text(store.t('historyHint')), findsNothing);
      expect(find.text(store.t('syncAccount')), findsNothing);
      final before = portal.scripts.length;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
      await frames(tester);
      expect(portal.scripts.length, greaterThan(before));
      expect(portal.scripts.last, contains('account-synced'));
      await synced([
        {
          'anime': {
            'id': '10',
            'title': 'Cloud History Anime',
            'cover': 'https://p2.bahamut.com.tw/10.jpg',
            'latestVideoId': '21',
            'sections': [],
          },
          'videoId': '20',
          'episodeLabel': '1',
          'progress': .4,
          'progressLabel': '08:00',
        },
      ]);
      expect(store.history.length, 1);
      expect(find.text('Cloud History Anime'), findsOneWidget);
      expect(find.text('08:00'), findsOneWidget);
      await tester.tap(find.text('Cloud History Anime'));
      await frames(tester);
      expect(portal.visited.last, OfficialSite.video('20'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tab pages slide in the selected direction and keep one tab bar',
    (tester) async {
      final store = await launch(tester);
      final bar = tester.state(find.byType(GlassTabBar));
      store.selectTab(4);
      await tester.pump();
      final moving = find.byKey(const ValueKey('tab-page-transition'));
      expect(
        tester.widget<Transform>(moving).transform.storage[12],
        greaterThan(0),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final midway = tester.widget<Transform>(moving).transform.storage[12];
      expect(midway, greaterThan(0));
      expect(midway, lessThan(24));
      store.selectTab(0);
      await tester.pump();
      expect(
        tester.widget<Transform>(moving).transform.storage[12],
        lessThan(0),
      );
      await frames(tester);
      expect(tester.widget<Transform>(moving).transform.storage[12], 0);
      expect(tester.state(find.byType(GlassTabBar)), same(bar));
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account card and header use the official profile and clear after logout',
    (tester) async {
      final store = await launch(tester);
      await store.attach(FakePortal());
      store.updateNavigation(
        OfficialSite.home.resolve('mygather.php'),
        canGoBack: false,
      );
      await store.syncAccount();
      Future<void> send(Map<String, dynamic> body) => store.receive(
        jsonEncode({...body, 'requestId': store.operation.id}),
        origin: OfficialSite.home,
        source: OfficialSite.home.resolve('mygather.php'),
        isMainFrame: true,
      );
      await send({
        'type': 'account-synced',
        'profile': {
          'id': 'fixture-user',
          'displayName': '測試暱稱',
          'avatar':
              'https://avatar2.bahamut.com.tw/avataruserpic/f/i/fixture-user/fixture-user.png',
        },
        'favorites': [],
        'history': [],
      });
      await frames(tester);
      final portrait = tester.widget<AccountPortrait>(
        find.descendant(
          of: find.byType(AccountAvatar).hitTestable(),
          matching: find.byType(AccountPortrait),
        ),
      );
      expect(portrait.profile?.id, 'fixture-user');
      await tester.tap(find.byType(AccountAvatar).hitTestable());
      await frames(tester);
      expect(find.text('測試暱稱'), findsOneWidget);
      expect(find.text('@fixture-user'), findsOneWidget);
      expect(find.text(store.t('localProfile')), findsNothing);
      await store.syncAccount();
      await send({'type': 'account-guest'});
      await frames(tester);
      expect(find.text('測試暱稱'), findsNothing);
      expect(find.text('@fixture-user'), findsNothing);
      expect(find.text(store.t('localProfile')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await frames(tester);
      expect(
        portal.scripts.last,
        contains('window.__bahaMediaSuspended = true'),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frames(tester);
      expect(
        portal.scripts.last,
        contains('window.__bahaMediaSuspended = false'),
      );
      expect(portal.scripts.last, isNot(contains('.play(')));
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
