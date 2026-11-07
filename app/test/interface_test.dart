import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:baha_plus/ui/seasonal_page.dart';
import 'core_test.dart' show MemoryStorage, FakePortal, FakeSearch;

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
      () =>
          AppStore.create(storage: MemoryStorage(), animeSearch: FakeSearch()),
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

  testWidgets('home uses episode artwork while a poster is unavailable', (
    tester,
  ) async {
    final store = await launch(tester);
    store.catalog = const Catalog(
      items: [
        Anime(
          id: '1',
          title: 'Seasonal Show',
          cover: 'https://p2.bahamut.com.tw/episode.jpg',
          latestVideoId: '101',
          sections: ['season'],
          updateDate: '2026-11-06',
        ),
      ],
    );
    store.selectTab(0);
    await frames(tester);
    final artwork = tester.widgetList<Artwork>(
      find.descendant(
        of: find.byKey(const ValueKey('featured-1')),
        matching: find.byType(Artwork),
      ),
    );
    expect(artwork, isNotEmpty);
    expect(
      artwork.every((item) => item.url == store.catalog.items.first.cover),
      isTrue,
    );
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
    expect((store.searchService as FakeSearch).queries, ['BahaNoMatch']);
    expect(find.text(store.t('officialSearch')), findsNothing);
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
    expect(find.text(store.t('connectAccount')), findsOneWidget);
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
      expect(
        tester.getSize(find.byType(GlassProgressIndicator)).width,
        greaterThan(80),
      );
      final navigations = portal.visited.length;
      await tester.tap(find.byKey(const ValueKey('history-play-10')));
      await frames(tester);
      expect(portal.visited.length, navigations + 1);
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
      final position = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .position;
      final moving = find.byKey(const ValueKey('tab-page-transition'));
      expect(
        tester.widget<Transform>(moving).transform.storage[12],
        greaterThan(0),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final midway = tester.widget<Transform>(moving).transform.storage[12];
      expect(midway, greaterThan(0));
      expect(midway, lessThan(24));
      await frames(tester);
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!
            .position,
        same(position),
      );
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
    'library uses the shared waterfall and favorites retain account filtering',
    (tester) async {
      final store = await launch(tester);
      store.catalog = Catalog(
        items: [
          for (var index = 1; index <= 20; index++)
            Anime(
              id: '$index',
              title: 'Library Anime $index',
              cover: 'https://p2.bahamut.com.tw/$index.jpg',
              sections: [index.isEven ? 'season' : 'hot'],
            ),
        ],
      );
      store.favorites = [
        const Anime(
          id: '99',
          title: 'Account Only Anime',
          cover: 'https://p2.bahamut.com.tw/99.jpg',
        ),
      ];
      store.accountSynced = true;
      store.selectTab(2);
      await frames(tester);
      expect(find.byKey(const ValueKey('library-waterfall')), findsOneWidget);
      final first = tester.getRect(find.byKey(const ValueKey('library-1')));
      final second = tester.getRect(find.byKey(const ValueKey('library-2')));
      expect(first.top, second.top);
      expect(first.left, lessThan(second.left));
      await tester.tap(find.text(store.t('favorites')).first);
      await frames(tester);
      expect(find.text('Account Only Anime'), findsOneWidget);
      expect(find.text('Library Anime 1'), findsNothing);
      await tester.tap(find.text('Account Only Anime'));
      await frames(tester);
      expect(store.selectedAnime?.id, '99');
      store.navigationFailed();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reselecting any bottom tab scrolls its current page to the top',
    (tester) async {
      final store = await launch(tester);
      final day =
          DateTime.now().toUtc().add(const Duration(hours: 8)).weekday % 7;
      store.catalog = Catalog(
        items: [
          for (var index = 1; index <= 40; index++)
            Anime(
              id: '$index',
              title: 'Scrolling Anime $index',
              cover: 'https://p2.bahamut.com.tw/$index.jpg',
              sections: const ['hot', 'season'],
              updateDay: day,
            ),
        ],
      );
      store.history = [
        for (final anime in store.catalog.items)
          WatchEntry.fromJson({
            'anime': anime.toJson(),
            'videoId': '${100 + int.parse(anime.id)}',
            'episodeLabel': '1',
          }),
      ];
      store.accountSynced = true;
      final labels = [
        'explore',
        'schedule',
        'library',
        'watchHistory',
        'search',
      ];
      for (var index = 0; index < labels.length; index++) {
        store.selectTab(index);
        await frames(tester);
        final view = find.byType(CustomScrollView);
        await tester.drag(view, const Offset(0, -500));
        await frames(tester);
        final controller = tester.widget<CustomScrollView>(view).controller!;
        expect(controller.offset, greaterThan(0), reason: labels[index]);
        await tester.tap(
          find
              .descendant(
                of: find.byType(GlassTabBar),
                matching: find.text(store.t(labels[index])),
              )
              .hitTestable()
              .first,
        );
        await frames(tester);
        expect(controller.offset, closeTo(0, .1), reason: labels[index]);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home uses a poster carousel and opens an episode timeline distinct from library season posters',
    (tester) async {
      final store = await launch(tester);
      store.catalog = const Catalog(
        items: [
          Anime(
            id: '1',
            title: 'First Seasonal Show',
            cover: 'https://p2.bahamut.com.tw/episode-1.jpg',
            poster: 'https://p2.bahamut.com.tw/poster-1.jpg',
            latestVideoId: '101',
            sections: ['season'],
            updateDate: '2026-11-06',
            updateTime: '10:00',
          ),
          Anime(
            id: '2',
            title: 'Second Seasonal Show',
            cover: 'https://p2.bahamut.com.tw/episode-2.jpg',
            poster: 'https://p2.bahamut.com.tw/poster-2.jpg',
            latestVideoId: '102',
            sections: ['season'],
            updateDate: '2026-11-05',
            updateTime: '09:00',
          ),
          Anime(
            id: '3',
            title: 'Promoted Popular Show',
            cover: 'https://p2.bahamut.com.tw/episode-3.jpg',
            poster: 'https://p2.bahamut.com.tw/poster-3.jpg',
            sections: ['hot'],
          ),
        ],
      );
      store.selectTab(0);
      await frames(tester);
      final carousel = find.byKey(const ValueKey('home-featured-carousel'));
      final pages = tester.widget<PageView>(
        find.descendant(of: carousel, matching: find.byType(PageView)),
      );
      expect(pages.childrenDelegate.estimatedChildCount, 3);
      final heroArt = tester.widgetList<Artwork>(
        find.descendant(
          of: find.byKey(const ValueKey('featured-1')),
          matching: find.byType(Artwork),
        ),
      );
      expect(heroArt, isNotEmpty);
      expect(
        heroArt.every((art) => art.url == store.catalog.items.first.poster),
        isTrue,
      );
      await tester.drag(carousel, const Offset(-280, 0));
      await frames(tester);
      expect(pages.controller!.page, greaterThan(.5));
      final heading = find.descendant(
        of: find.byType(SectionHeading),
        matching: find.text(store.t('seasonal')),
      );
      await Scrollable.ensureVisible(tester.element(heading), alignment: .35);
      await frames(tester);
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: heading, matching: find.byType(SectionHeading)),
          matching: find.byType(CupertinoButton),
        ),
      );
      await frames(tester);
      expect(find.byType(SeasonalPage), findsOneWidget);
      expect(store.tab, 0);
      expect(find.text('11/06 週五'), findsOneWidget);
      final timelineImage = find.descendant(
        of: find.byKey(const ValueKey('timeline-1')),
        matching: find.byType(Artwork),
      );
      expect(
        tester.widget<Artwork>(timelineImage).url,
        store.catalog.items.first.cover,
      );
      final imageRect = tester.getRect(timelineImage);
      expect(imageRect.width / imageRect.height, closeTo(16 / 9, .01));
      await tester.tap(find.bySemanticsLabel(store.t('back')));
      await frames(tester);
      store.selectTab(2, filter: 'season');
      await frames(tester);
      final poster = find.descendant(
        of: find.byKey(const ValueKey('library-1')),
        matching: find.byType(Artwork),
      );
      expect(
        tester.widget<Artwork>(poster).url,
        store.catalog.items.first.poster,
      );
      expect(
        tester.getRect(poster).width / tester.getRect(poster).height,
        closeTo(.72, .01),
      );
      store.selectTab(0);
      await frames(tester);
      await Scrollable.ensureVisible(tester.element(heading), alignment: .35);
      await frames(tester);
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: heading, matching: find.byType(SectionHeading)),
          matching: find.byType(CupertinoButton),
        ),
      );
      await frames(tester);
      await tester.tap(find.byKey(const ValueKey('timeline-1')));
      await frames(tester);
      expect(find.byType(DetailPage), findsOneWidget);
      await tester.tap(find.text(store.t('playLatest')));
      await frames(tester);
      expect(find.byType(DetailPage), findsNothing);
      expect(find.byType(SeasonalPage), findsNothing);
      expect(store.playingVideoId, '101');
      expect(store.browserVisible, isTrue);
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
      final portal = FakePortal()
        ..communityResponse = {
          'ok': true,
          'messageId': '123',
          'total': 0,
          'nextPage': 0,
          'comments': <Json>[],
        };
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
      final danmakuButton = tester.getRect(
        find.byKey(const ValueKey('player-danmaku-button')),
      );
      expect(video.contains(danmakuButton.center), isTrue);
      expect(
        video.contains(
          tester.getCenter(find.byKey(const ValueKey('player-danmaku-send'))),
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('player-danmaku-send')));
      await frames(tester);
      expect(find.byKey(const ValueKey('danmaku-composer')), findsOneWidget);
      expect(find.byKey(const ValueKey('community-input-60')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('community-input-60')),
        '測試彈幕',
      );
      await frames(tester);
      await tester.tap(find.byIcon(CupertinoIcons.arrow_up_circle_fill));
      await frames(tester);
      expect(portal.communityRequests.last['text'], '測試彈幕');
      expect(portal.communityRequests.last['videoId'], '20');
      expect(find.text('測試彈幕'), findsNothing);
      await tester.tap(find.bySemanticsLabel(store.t('close')).last);
      await frames(tester);
      await tester.tap(find.byKey(const ValueKey('player-danmaku-button')));
      await frames(tester);
      expect(store.danmakuSettings.enabled, isFalse);
      expect(find.byKey(const ValueKey('player-danmaku-send')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('player-danmaku-button')));
      await frames(tester);
      expect(store.danmakuSettings.enabled, isTrue);
      expect(find.byKey(const ValueKey('player-danmaku-send')), findsOneWidget);
      expect(find.text(store.t('danmaku')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('synopsis-section'))).dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('compact-comments-preview')),
              )
              .dy,
        ),
      );
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
      expect(controlBar.top, greaterThanOrEqualTo(video.bottom));
      expect(
        controlBar.bottom,
        lessThan(tester.getTopLeft(find.text('Test Anime')).dy),
      );
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
      final fullVideo = tester.getRect(
        find.byKey(const ValueKey('test-video-surface')),
      );
      final fullControlBar = tester.getRect(
        find.byKey(const ValueKey('video-glass-controls')),
      );
      expect(fullVideo.contains(fullControlBar.topLeft), isTrue);
      expect(fullVideo.contains(fullControlBar.bottomRight), isTrue);
      expect(fullControlBar.height, greaterThan(controlBar.height));
      expect(
        tester.getSize(find.bySemanticsLabel(store.t('pausePlayback'))).height,
        greaterThanOrEqualTo(52),
      );
      expect(
        fullVideo.contains(
          tester.getCenter(find.byKey(const ValueKey('player-danmaku-button'))),
        ),
        isTrue,
      );
      tester.view.physicalSize = const Size(850, 400);
      await frames(tester);
      expect(find.byKey(const ValueKey('player-danmaku-send')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-danmaku-button')));
      await frames(tester);
      expect(find.byKey(const ValueKey('player-danmaku-send')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('player-danmaku-button')));
      await frames(tester);
      await tester.tap(find.byKey(const ValueKey('player-danmaku-send')));
      await frames(tester);
      expect(find.byKey(const ValueKey('danmaku-composer')), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await frames(tester);
      expect(find.byKey(const ValueKey('community-input-60')), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await frames(tester);
      await tester.tap(find.bySemanticsLabel(store.t('close')).last);
      tester.view.physicalSize = const Size(400, 850);
      await frames(tester);
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
  testWidgets(
    'portrait controls stay visible while fullscreen controls can be dismissed',
    (tester) async {
      final store = await launch(tester);
      final portal = FakePortal()
        ..communityResponse = {
          'ok': true,
          'messageId': '123',
          'total': 0,
          'nextPage': 0,
          'comments': <Json>[],
        };
      await store.attach(portal);
      await store.play(
        const Anime(
          id: '10',
          title: 'Test Anime',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
          latestVideoId: '20',
        ),
      );
      var officialTaps = 0;
      Navigator.of(tester.element(find.byType(AppRoot))).push(
        CupertinoPageRoute<void>(
          builder: (_) => PlayerPage(
            store: store,
            video: GestureDetector(
              onTap: () => officialTaps++,
              child: const ColoredBox(
                key: ValueKey('test-video-surface'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      );
      void playback({
        PlaybackPhase phase = PlaybackPhase.content,
        bool paused = true,
      }) {
        store.playback.value = PlaybackState(
          phase: phase,
          surfaceReady: true,
          paused: paused,
          buffering: false,
          position: 37,
          duration: 1200,
        );
      }

      playback();
      await frames(tester);
      final controls = find.byKey(const ValueKey('video-glass-controls'));
      final rewind = find.bySemanticsLabel(store.t('rewindTen'));
      final surface = find.byKey(const ValueKey('test-video-surface'));
      expect(rewind.hitTestable(), findsOneWidget);
      var video = tester.getRect(surface);
      final background = video.topLeft + const Offset(20, 40);

      tester.view.physicalSize = const Size(320, 850);
      await frames(tester);
      expect(rewind.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(400, 850);
      await frames(tester);

      await tester.tapAt(background);
      await frames(tester);
      expect(rewind.hitTestable(), findsOneWidget);
      await tester.tapAt(background);
      await frames(tester);
      expect(rewind.hitTestable(), findsOneWidget);
      expect(officialTaps, 0);

      await tester.tap(find.bySemanticsLabel(store.t('rewindTen')));
      await frames(tester);
      expect(portal.scripts.last, contains('"seek"'));
      expect(rewind.hitTestable(), findsOneWidget);
      await tester.tapAt(Offset(5, video.bottom + 10));
      await frames(tester);
      expect(rewind.hitTestable(), findsOneWidget);

      playback(paused: false);
      await frames(tester);
      expect(rewind.hitTestable(), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await frames(tester);
      expect(rewind.hitTestable(), findsOneWidget);
      await tester.tapAt(background);
      await frames(tester);
      expect(rewind.hitTestable(), findsOneWidget);

      playback(phase: PlaybackPhase.age);
      await frames(tester);
      await tester.tapAt(background);
      expect(officialTaps, 1);

      playback();
      store.setPlayerFullscreen(true);
      await frames(tester);
      video = tester.getRect(surface);
      final exitFullscreen = find.byKey(
        const ValueKey('player-fullscreen-close'),
      );
      final danmaku = find.byKey(const ValueKey('player-danmaku-button'));
      final settings = find.bySemanticsLabel(store.t('playbackSettings'));
      expect(exitFullscreen.hitTestable(), findsOneWidget);
      expect(danmaku.hitTestable(), findsOneWidget);
      expect(settings.hitTestable(), findsOneWidget);
      await tester.tapAt(video.center);
      await frames(tester);
      expect(controls.hitTestable(), findsNothing);
      expect(exitFullscreen.hitTestable(), findsNothing);
      expect(danmaku.hitTestable(), findsNothing);
      expect(settings.hitTestable(), findsNothing);
      await tester.tapAt(video.center);
      await frames(tester);
      expect(controls.hitTestable(), findsOneWidget);
      expect(exitFullscreen.hitTestable(), findsOneWidget);
      expect(danmaku.hitTestable(), findsOneWidget);
      expect(settings.hitTestable(), findsOneWidget);
      playback(paused: false);
      await frames(tester);
      await tester.pump(const Duration(seconds: 3));
      await frames(tester);
      expect(controls.hitTestable(), findsNothing);
      expect(exitFullscreen.hitTestable(), findsNothing);
      expect(danmaku.hitTestable(), findsNothing);
      expect(settings.hitTestable(), findsNothing);
      await tester.tapAt(video.center);
      await frames(tester);
      expect(controls.hitTestable(), findsOneWidget);
      expect(exitFullscreen.hitTestable(), findsOneWidget);
      expect(danmaku.hitTestable(), findsOneWidget);
      expect(settings.hitTestable(), findsOneWidget);
      await tester.tap(
        find.bySemanticsLabel(store.t('playbackSettings')).hitTestable(),
      );
      await frames(tester);
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.text(store.t('connectAccount')), findsNothing);
      await tester.tapAt(const Offset(10, 100));
      await frames(tester);
      expect(find.byType(CupertinoActionSheet), findsNothing);
      store.setPlayerFullscreen(false);
      await frames(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
