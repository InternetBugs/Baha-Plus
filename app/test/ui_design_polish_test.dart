import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/account_page.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/collection_page.dart';
import 'package:baha_plus/ui/comments_page.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:baha_plus/ui/diagnostics_page.dart';
import 'package:baha_plus/ui/native_http_player.dart';
import 'package:baha_plus/ui/notifications_page.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:baha_plus/ui/seasonal_page.dart';
import 'package:baha_plus/ui/synopsis_section.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'community_test.dart' show commentPageJson, notificationJson;
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'fake_metadata.dart';
import 'fake_playback.dart';
import 'native_http_api_test.dart' show HttpFixture;
import 'native_playback_test.dart' show FakeVideo;

void main() {
  Future<void> frames(WidgetTester tester, {int count = 12}) async {
    for (var frame = 0; frame < count; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Catalog richCatalog() {
    final today =
        DateTime.now().toUtc().add(const Duration(hours: 8)).weekday % 7;
    final items = [
      for (var i = 1; i <= 12; i++)
        Anime(
          id: '$i',
          title: i == 1
              ? '超長測試動畫標題用於驗證大字體與動態排版下不會發生任何溢出問題 第四季'
              : '測試動畫作品 $i',
          cover: 'https://p2.bahamut.com.tw/cover-$i.jpg',
          poster: 'https://p2.bahamut.com.tw/poster-$i.jpg',
          year: '2026',
          episodeLabel: '第 $i 集',
          latestVideoId: '${100 + i}',
          sections: [
            if (i <= 8) 'season',
            if (i >= 3) 'hot',
            if (i <= 6) 'new',
          ],
          updateDay: today,
          updateDate: i <= 4 ? '2026-11-25' : '2026-11-24',
          updateTime: '${(10 + i).toString().padLeft(2, '0')}:30',
          addedDate: i <= 6 ? '11/25' : null,
          views: '${i * 25000}',
        ),
    ];
    return Catalog(
      fetchedAt: '2026-11-25T00:00:00Z',
      items: items,
      collections: [
        AnimeCollection(
          id: 'topic-1',
          title: '秋季必看精選主題片單',
          intro: '嚴選本季最具話題性的原創與改編作品。',
          items: items.take(4).toList(),
        ),
        AnimeCollection(
          id: 'expiring-all',
          title: '即將下架',
          items: items.skip(4).take(4).toList(),
          expiring: true,
        ),
      ],
    );
  }

  AnimeDetail richDetail() => AnimeDetail.fromJson({
    'title': '超長測試動畫標題用於驗證大字體與動態排版下不會發生任何溢出問題 第四季',
    'description': '這是一段非常詳細的作品簡介，用於測試詳情頁、播放器與完整簡介頁面在大字體模式下是否能夠流暢顯示。' * 10,
    'episodes': [
      {'id': '101', 'label': '1'},
      {'id': '102', 'label': '2'},
      {'id': '103', 'label': '3'},
      {'id': '104', 'label': '特別篇'},
    ],
    'metadata': [
      {'label': '製作廠商', 'value': '星光動畫工作室'},
      {'label': '作品分類', 'value': '奇幻、冒險、日常'},
      {'label': '首播年份', 'value': '2026'},
    ],
    'rating': {
      'value': 4.9,
      'count': 12840,
      'distribution': [120, 180, 420, 1620, 10500],
    },
  });

  Future<(AppStore, FakePortal)> createApp(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1.0,
    EdgeInsets padding = const EdgeInsets.only(top: 44, bottom: 34),
    String language = 'zh-Hans',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
    );
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);

    final portal = FakePortal()
      ..communityResponse = commentPageJson(id: '1')
      ..accountApi.communityResponse = commentPageJson(id: '1');
    final store = (await tester.runAsync(
      () => AppStore.create(
        nativeHttpApiFactory: PendingNativeHttpApi.new,
        metadataApi: FakeMetadata(),
        accountApi: portal.accountApi,
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
      ),
    ))!;
    addTearDown(store.dispose);
    await store.setLanguage(language);
    store
      ..catalog = richCatalog()
      ..accountSynced = true
      ..history = [
        WatchEntry.fromJson({
          'anime': store.catalog.items.first.toJson(),
          'videoId': '101',
          'episodeLabel': '1',
          'progress': .65,
          'progressLabel': '15:30',
          'nextVideoId': '102',
        }),
      ];

    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: padding,
            viewPadding: padding,
            textScaler: TextScaler.linear(textScale),
          ),
          child: BahaPlusApp(store: store, mountPortal: false),
        ),
      ),
    );
    await frames(tester);
    return (store, portal);
  }

  testWidgets(
    'GlassNoticeToast surfaces repeated notices and dismisses cleanly',
    (tester) async {
      final (store, _) = await createApp(tester);
      expect(find.byKey(const ValueKey('global-notice-toast')), findsNothing);

      store.notice = store.t('added');
      await frames(tester, count: 6);
      expect(find.byKey(const ValueKey('global-notice-toast')), findsOneWidget);
      expect(find.text(store.t('added')), findsOneWidget);

      // Tap to dismiss immediately; once fade-out completes the toast unmounts
      // so no invisible GlassContainer layer remains resident over the app.
      await tester.tap(find.byKey(const ValueKey('global-notice-toast')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.byKey(const ValueKey('global-notice-toast')), findsNothing);

      // Trigger the exact same notice again and verify auto-dismiss after 2.6s.
      store.notice = store.t('added');
      await frames(tester, count: 6);
      final opacityOnRepeat = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byKey(const ValueKey('global-notice-toast')),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(opacityOnRepeat.opacity, 1);

      await tester.pump(const Duration(milliseconds: 2700));
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.byKey(const ValueKey('global-notice-toast')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library filter stays decoupled from global search and offers a full-catalog handoff',
    (tester) async {
      final (store, _) = await createApp(tester);
      final search = store.searchService as FakeSearch;
      store.selectTab(2);
      await frames(tester);

      // Filter inside Library without polluting global search query or hitting network.
      final filterField = find.descendant(
        of: find.byKey(const ValueKey('library-filter-bar')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(filterField, '冷门不存在的作品');
      await frames(tester);
      expect(store.libraryQuery, '冷门不存在的作品');
      expect(store.query, isEmpty);
      expect(search.queries, isEmpty);

      // Switching segments inside Library keeps the local filter text.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('library-filter-control')),
          matching: find.text(store.t('hotFilter')),
        ),
      );
      await frames(tester);
      expect(store.libraryFilter, 'hot');
      expect(store.libraryQuery, '冷门不存在的作品');

      // Tapping the full-catalog handoff jumps to Search tab and queries official search.
      final handoff = find.byKey(const ValueKey('library-search-full-catalog'));
      expect(handoff, findsOneWidget);
      await tester.tap(handoff);
      await frames(tester);
      expect(store.tab, 4);
      expect(store.query, '冷门不存在的作品');
      expect(search.queries, ['冷门不存在的作品']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pull-to-refresh sits below the top safe area and GlassAppBar on scrollable pages',
    (tester) async {
      const topSafe = 44.0;
      await createApp(
        tester,
        padding: const EdgeInsets.only(top: topSafe, bottom: 34),
      );
      final rootRefresh = tester.widget<BahaSliverRefreshControl>(
        find.byType(BahaSliverRefreshControl),
      );
      expect(rootRefresh.topInset, topSafe + 44.0);
      final rootPadding = tester.widget<SliverPadding>(
        find.descendant(
          of: find.byType(BahaSliverRefreshControl),
          matching: find.byType(SliverPadding),
        ),
      );
      expect(rootPadding.padding, const EdgeInsets.only(top: topSafe + 44.0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow phone at 1.8x Dynamic Type renders all primary and secondary screens without overflow',
    (tester) async {
      final (store, portal) = await createApp(
        tester,
        size: const Size(320, 640),
        textScale: 1.8,
        padding: const EdgeInsets.only(top: 24, bottom: 16),
      );
      portal.accountApi.communityResponse = {
        'ok': true,
        'owner': 'reader',
        'items': [notificationJson('101')],
      };

      // Home tab (Hero + Continue Watching + Recent Updates + Newly Added + Topics + Popular).
      expect(find.byKey(const ValueKey('home-featured-carousel')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Schedule tab.
      store.selectTab(1);
      await frames(tester);
      expect(
        find.byKey(const ValueKey('schedule-weekday-control')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Library tab.
      store.selectTab(2);
      await frames(tester);
      expect(find.byKey(const ValueKey('library-filter-control')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // History tab.
      store.selectTab(3);
      await frames(tester);
      expect(find.byKey(const ValueKey('history-play-1')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Detail page with long title, rating, metadata, and episodes.
      store.detail = richDetail();
      Future<void> mountScreen(Widget page) async {
        await tester.pumpWidget(
          LiquidGlassWidgets.wrap(
            brightnessResolver: Theme.maybeBrightnessOf,
            theme: GlassThemeData.simple(quality: GlassQuality.standard),
            child: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                padding: EdgeInsets.only(top: 24, bottom: 16),
                viewPadding: EdgeInsets.only(top: 24, bottom: 16),
                textScaler: TextScaler.linear(1.8),
              ),
              child: MaterialApp(home: page),
            ),
          ),
        );
        await frames(tester);
        expect(tester.takeException(), isNull);
      }

      await mountScreen(
        DetailPage(store: store, anime: store.catalog.items.first),
      );
      await mountScreen(SeasonalPage(store: store, openDetail: (_) {}));
      await mountScreen(
        CollectionPage(
          store: store,
          collection: store.catalog.collections.first,
          openDetail: (_) {},
        ),
      );
      await mountScreen(NotificationsPage(store: store));
      await mountScreen(
        AccountPage(store: store, onCheckUpdates: () {}),
      );
      await tester.scrollUntilVisible(
        find.text(store.t('checkUpdates')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await frames(tester);
      // Merged About section shows check-updates row with version once (no duplicate Baha Plus row).
      expect(find.text('Baha Plus'), findsNothing);
      expect(find.text(store.t('checkUpdates')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'top-bar navigation icons are consistent across push and modal pages',
    (tester) async {
      final (store, _) = await createApp(tester);

      Future<GlassAppBar> inspectAppBar(Widget page) async {
        await tester.pumpWidget(
          LiquidGlassWidgets.wrap(
            brightnessResolver: Theme.maybeBrightnessOf,
            theme: GlassThemeData.simple(quality: GlassQuality.standard),
            child: MaterialApp(home: page),
          ),
        );
        await frames(tester);
        expect(tester.takeException(), isNull);
        return tester.widget<GlassAppBar>(find.byType(GlassAppBar));
      }

      // Push pages use chevron_back on the leading side.
      for (final page in [
        SeasonalPage(store: store, openDetail: (_) {}),
        CollectionPage(
          store: store,
          collection: store.catalog.collections.first,
          openDetail: (_) {},
        ),
        NotificationsPage(store: store),
        DiagnosticsPage(store: store),
      ]) {
        final bar = await inspectAppBar(page);
        expect(bar.leading, isNotNull);
        expect(
          find.descendant(
            of: find.byType(GlassAppBar),
            matching: find.byIcon(CupertinoIcons.chevron_back),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(GlassAppBar),
            matching: find.bySemanticsLabel(store.t('back')),
          ),
          findsOneWidget,
        );
      }

      // Modal pages put xmark close in top-right actions (leading is null).
      store.playingAnime = store.catalog.items.first;
      store.playingVideoId = '101';
      for (final page in [
        DetailPage(store: store, anime: store.catalog.items.first),
        SynopsisPage(store: store, title: 'Title', description: 'Body'),
        CommentsPage(store: store, videoId: '101', title: 'Title'),
        PlayerPage(
          store: store,
          video: const ColoredBox(color: Colors.black),
        ),
        AccountPage(store: store, onCheckUpdates: () {}),
      ]) {
        final bar = await inspectAppBar(page);
        expect(bar.leading, isNull);
        expect(bar.actions, isNotEmpty);
        expect(
          find.descendant(
            of: find.byType(GlassAppBar),
            matching: find.byIcon(CupertinoIcons.xmark),
          ),
          findsOneWidget,
        );
      }

      // CommentsPage floats CommunityComposer in GlassScaffold.bodyOverlays with bottom edge fade.
      await inspectAppBar(
        CommentsPage(store: store, videoId: '101', title: 'Title'),
      );
      final scaffold = tester.widget<GlassScaffold>(
        find.byKey(const ValueKey('comments-page')),
      );
      expect(scaffold.bottomEdgeFade, isTrue);
      expect(scaffold.bodyOverlays, isNotEmpty);
    },
  );

  testWidgets(
    'ContinueCard opens detail on card tap while play button resumes playback',
    (tester) async {
      final (store, _) = await createApp(tester);
      store.selectTab(3);
      await frames(tester);

      // Tapping the card title opens DetailPage.
      await tester.tap(find.text(store.catalog.items.first.title));
      await frames(tester);
      expect(find.byType(DetailPage), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(store.t('close')));
      await frames(tester);
      expect(find.byType(DetailPage), findsNothing);

      // Tapping the dedicated play button resumes playback directly.
      await tester.tap(find.byKey(const ValueKey('history-play-1')));
      await frames(tester);
      expect(store.playingVideoId, '101');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fullscreen player exposes episode switcher, speed badge, ended next-episode pill and safe-area ad skip',
    (tester) async {
      final video = FakeVideo();
      final previousPlatform = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = video;
      addTearDown(() => VideoPlayerPlatform.instance = previousPlatform);

      final fixture = HttpFixture(ads: true);
      const size = Size(844, 390);
      const padding = EdgeInsets.only(left: 59, right: 59, bottom: 21);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(
        left: padding.left,
        top: padding.top,
        right: padding.right,
        bottom: padding.bottom,
      );
      tester.view.viewPadding = tester.view.padding;
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
      await store.setLanguage('zh-Hans');

      final anime = richCatalog().items.first;
      await tester.runAsync(() => store.play(anime));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.runAsync(store.nativeHttpPlayback!.consent);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      store
        ..playerDetail = richDetail()
        ..playingVideoId = '101'
        ..setPlayerFullscreen(true);

      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MediaQuery(
            data: const MediaQueryData(
              size: size,
              padding: padding,
              viewPadding: padding,
            ),
            child: MaterialApp(home: NativeHttpPlayer(store: store)),
          ),
        ),
      );
      await frames(tester);

      // AdSkipCapsule clears fullscreen safe area insets on right & bottom.
      final skipRect = tester.getRect(find.byKey(const ValueKey('http-skip-ad')));
      expect(size.width - skipRect.right, greaterThanOrEqualTo(padding.right));
      expect(
        size.height - skipRect.bottom,
        greaterThanOrEqualTo(padding.bottom),
      );

      // Transition to content with 1.5x rate and verify title + rate badge + episodes button.
      store.playback.value = const PlaybackState(
        phase: PlaybackPhase.content,
        surfaceReady: true,
        paused: true,
        buffering: false,
        duration: 1440,
        position: 600,
        rate: 1.5,
      );
      await frames(tester);

      expect(find.textContaining('第 1 集'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-rate-badge')), findsOneWidget);
      expect(find.text('1.5×'), findsOneWidget);

      final epBtn = find.byKey(const ValueKey('player-fullscreen-episodes'));
      expect(epBtn, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-bottom-right-wing')),
          matching: epBtn,
        ),
        findsOneWidget,
      );

      // The overflow settings menu does not duplicate the episodes action.
      await tester.tap(find.bySemanticsLabel(store.t('playbackSettings')));
      await frames(tester);
      expect(find.byKey(const ValueKey('player-menu-refresh')), findsOneWidget);
      expect(find.byKey(const ValueKey('player-menu-episodes')), findsNothing);
      await tester.tapAt(const Offset(10, 100));
      await frames(tester);

      await tester.tap(epBtn);
      await frames(tester);
      expect(
        find.byKey(const ValueKey('player-fullscreen-episodes-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('fullscreen-ep-102')), findsOneWidget);
      // Close dialog cleanly.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('player-fullscreen-episodes-dialog')),
          matching: find.bySemanticsLabel(store.t('close')),
        ),
      );
      await frames(tester);
      expect(
        find.byKey(const ValueKey('player-fullscreen-episodes-dialog')),
        findsNothing,
      );

      // When episode ends, show prominent next-episode glass pill.
      store.playback.value = const PlaybackState(
        phase: PlaybackPhase.content,
        surfaceReady: true,
        paused: true,
        buffering: false,
        ended: true,
        duration: 1440,
        position: 1440,
        rate: 1.0,
      );
      await frames(tester);
      expect(find.byKey(const ValueKey('player-rate-badge')), findsNothing);
      final nextPill = find.byKey(const ValueKey('player-ended-next-episode'));
      expect(nextPill, findsOneWidget);
      expect(find.textContaining(store.t('playNextEpisode')), findsOneWidget);
      await tester.tap(nextPill);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await frames(tester);
      expect(store.playingVideoId, '102');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'portrait player uses wider mobile media insets, 40pt top capsule, and separated time bar without overflow',
    (tester) async {
      final (store, _) = await createApp(
        tester,
        size: const Size(390, 844),
        padding: const EdgeInsets.only(top: 44, bottom: 34),
      );
      final anime = store.catalog.items.first;
      store
        ..playingAnime = anime
        ..playingVideoId = '101'
        ..playerDetail = richDetail()
        ..playback.value = const PlaybackState(
          phase: PlaybackPhase.content,
          surfaceReady: true,
          paused: true,
          duration: 1440,
          position: 125,
          hasDanmaku: true,
        );

      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 44, bottom: 34),
              viewPadding: EdgeInsets.only(top: 44, bottom: 34),
            ),
            child: MaterialApp(
              home: PlayerPage(
                store: store,
                video: const ColoredBox(
                  key: ValueKey('portrait-video-fixture'),
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
      );
      await frames(tester);

      final videoRect = tester.getRect(
        find.byKey(const ValueKey('portrait-video-fixture')),
      );
      final controlsRect = tester.getRect(
        find.byKey(const ValueKey('video-glass-controls')),
      );
      final topCapsuleRect = tester.getRect(
        find.byKey(const ValueKey('player-portrait-actions-capsule')),
      );
      final titleRect = tester.getRect(find.text(anime.title));

      expect(videoRect.left, closeTo(12, .5));
      expect(controlsRect.left, closeTo(12, .5));
      expect(controlsRect.width, closeTo(videoRect.width, .5));
      expect(titleRect.left, greaterThan(videoRect.left));
      expect(topCapsuleRect.height, closeTo(40, 1));
      expect(find.text('02:05'), findsOneWidget);
      expect(find.text('24:00'), findsOneWidget);
      expect(
        tester.getSize(find.bySemanticsLabel(store.t('resumePlayback'))).height,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
