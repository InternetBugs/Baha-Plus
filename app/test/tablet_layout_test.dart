import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/account_page.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/comments_page.dart';
import 'package:baha_plus/ui/danmaku_panel.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:baha_plus/ui/diagnostics_page.dart';
import 'package:baha_plus/ui/glass_settings_menu.dart';
import 'package:baha_plus/ui/notifications_page.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:baha_plus/ui/seasonal_page.dart';
import 'package:baha_plus/ui/synopsis_section.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'community_test.dart' show commentPageJson, notificationJson;
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'fake_account.dart';
import 'fake_metadata.dart';
import 'fake_playback.dart';

class _StatefulVideoFixture extends StatefulWidget {
  const _StatefulVideoFixture({super.key});

  @override
  State<_StatefulVideoFixture> createState() => _StatefulVideoFixtureState();
}

class _StatefulVideoFixtureState extends State<_StatefulVideoFixture> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

void main() {
  Future<void> frames(WidgetTester tester, {int count = 12}) async {
    for (var frame = 0; frame < count; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Catalog sampleCatalog() {
    final today =
        DateTime.now().toUtc().add(const Duration(hours: 8)).weekday % 7;
    return Catalog(
      fetchedAt: '2026-11-25T00:00:00Z',
      items: [
        for (var i = 1; i <= 18; i++)
          Anime(
            id: '$i',
            title: '平板測試動畫 $i',
            cover: 'https://p2.bahamut.com.tw/cover-$i.jpg',
            poster: 'https://p2.bahamut.com.tw/poster-$i.jpg',
            year: '2026',
            episodeLabel: '第 $i 集',
            latestVideoId: '${100 + i}',
            sections: [
              if (i <= 10) 'season',
              if (i > 4) 'hot',
            ],
            updateDay: today,
            updateDate: i <= 5 ? '2026-11-25' : '2026-11-24',
            updateTime: '${(10 + i).toString().padLeft(2, '0')}:00',
          ),
      ],
    );
  }

  AnimeDetail sampleDetail() => AnimeDetail.fromJson({
    'title': '平板測試動畫 1',
    'description': '這是一段適合在平板雙欄介面閱讀的完整故事簡介。' * 14,
    'episodes': [
      for (var i = 1; i <= 12; i++) {'id': '${100 + i}', 'label': '$i'},
    ],
    'metadata': [
      {'label': '作品類型', 'value': '奇幻、冒險'},
      {'label': '製作廠商', 'value': '星光動畫工作室'},
      {'label': '首播年份', 'value': '2026'},
    ],
    'rating': {
      'value': 4.8,
      'count': 1234,
      'distribution': [12, 18, 45, 159, 1000],
    },
  });

  Future<(AppStore, FakePortal)> launchApp(
    WidgetTester tester, {
    required Size size,
    String appearance = 'light',
    double textScale = 1,
    EdgeInsets padding = EdgeInsets.zero,
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
    await store.setLanguage('zh-Hans');
    await store.setAppearance(appearance);
    store
      ..catalog = sampleCatalog()
      ..accountSynced = true
      ..history = [
        for (var i = 1; i <= 6; i++)
          WatchEntry.fromJson({
            'anime': store.catalog.items[i - 1].toJson(),
            'videoId': '${100 + i}',
            'episodeLabel': '$i',
            'progress': .6,
            'progressLabel': '14:20',
            'nextVideoId': '${101 + i}',
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

  for (final (label, size, platform) in [
    ('iPad portrait', const Size(820, 1180), TargetPlatform.iOS),
    ('Android tablet portrait', const Size(800, 1280), TargetPlatform.android),
  ]) {
    testWidgets(
      '$label centers the bottom glass bar, shows multi-card carousel and centered modal sheet',
      (tester) async {
        final (store, _) = await launchApp(tester, size: size);

        expect(find.byKey(const ValueKey('main-tab-bar')), findsOneWidget);
        expect(find.byKey(const ValueKey('main-navigation-rail')), findsNothing);

        final tabBar = tester.widget<GlassTabBar>(
          find.byKey(const ValueKey('main-tab-bar')),
        );
        expect(
          tabBar.horizontalPadding,
          closeTo((size.width - 500) / 2, .5),
        );

        // Carousel shows multiple poster cards side by side instead of stretching one poster.
        final firstFeatured = tester.getRect(
          find.byKey(const ValueKey('featured-1')),
        );
        final secondFeatured = tester.getRect(
          find.byKey(const ValueKey('featured-2')),
        );
        expect(firstFeatured.width, lessThan(420));
        expect(secondFeatured.left, greaterThan(firstFeatured.left));
        expect(secondFeatured.left, lessThan(size.width));

        // Account opens as a centered floating tablet page sheet.
        await tester.tap(find.byType(AccountAvatar).hitTestable());
        await frames(tester);
        final sheetFinder = find.byKey(const ValueKey('tablet-modal-sheet'));
        expect(sheetFinder, findsOneWidget);
        expect(find.byType(AccountPage), findsOneWidget);
        final sheetRect = tester.getRect(sheetFinder);
        expect(sheetRect.width, lessThanOrEqualTo(580));
        expect(sheetRect.left, greaterThan(50));
        expect(sheetRect.right, lessThan(size.width - 50));
        final accountGroupRect = tester.getRect(
          find.byType(GlassSettingsGroup).first,
        );
        expect(accountGroupRect.width, closeTo(sheetRect.width - 40, 2));

        await tester.tap(find.bySemanticsLabel(store.t('close')).last);
        await frames(tester);
        expect(sheetFinder, findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final (label, size, platform, appearance) in [
    ('iPad landscape light', const Size(1180, 820), TargetPlatform.iOS, 'light'),
    (
      'Android tablet landscape dark',
      const Size(1280, 800),
      TargetPlatform.android,
      'dark',
    ),
    ('iPad Pro 13 landscape', const Size(1366, 1024), TargetPlatform.iOS, 'dark'),
  ]) {
    testWidgets(
      '$label uses floating GlassNavigationRail and adapts every top-level tab',
      (tester) async {
        final (store, _) = await launchApp(
          tester,
          size: size,
          appearance: appearance,
          padding: const EdgeInsets.only(top: 24, bottom: 20),
        );

        final rail = find.byKey(const ValueKey('main-navigation-rail'));
        expect(rail, findsOneWidget);
        expect(find.byKey(const ValueKey('main-tab-bar')), findsNothing);

        final railRect = tester.getRect(rail);
        final titleRect = tester.getRect(
          find.descendant(
            of: find.byType(GlassLargeTitle),
            matching: find.text(store.t('explore')),
          ),
        );
        expect(railRect.right, lessThan(titleRect.left));

        // Scroll down and reselect active rail tab to scroll back to top.
        final scrollView = find.byType(CustomScrollView);
        await tester.drag(scrollView, const Offset(0, -400));
        await frames(tester);
        final controller =
            tester.widget<CustomScrollView>(scrollView).controller!;
        expect(controller.offset, greaterThan(0));
        await tester.tap(find.byKey(const ValueKey('rail-tab-0')));
        await frames(tester);
        expect(controller.offset, closeTo(0, .5));

        // Account modal sheet on wide landscape tablets keeps full card content width.
        await tester.tap(find.byType(AccountAvatar).hitTestable());
        await frames(tester);
        final sheetFinder = find.byKey(const ValueKey('tablet-modal-sheet'));
        expect(sheetFinder, findsOneWidget);
        final sheetRect = tester.getRect(sheetFinder);
        final accountGroupRect = tester.getRect(
          find.byType(GlassSettingsGroup).first,
        );
        expect(accountGroupRect.width, closeTo(sheetRect.width - 40, 2));
        await tester.tap(find.bySemanticsLabel(store.t('close')).last);
        await frames(tester);
        expect(sheetFinder, findsNothing);

        // Switch to Schedule tab via rail.
        await tester.tap(find.byKey(const ValueKey('rail-tab-1')));
        await frames(tester);
        expect(store.tab, 1);
        expect(
          find.byType(CupertinoSlidingSegmentedControl<int>),
          findsNothing,
        );
        final weekdayControl = tester.getRect(
          find.byKey(const ValueKey('schedule-weekday-control')),
        );
        expect(weekdayControl.width, lessThanOrEqualTo(560.5));

        // Switch to Library tab via rail: constrained search + multi-column waterfall.
        await tester.tap(find.byKey(const ValueKey('rail-tab-2')));
        await frames(tester);
        expect(store.tab, 2);
        final searchRect = tester.getRect(find.byType(GlassSearchBar));
        expect(searchRect.width, lessThanOrEqualTo(560.5));
        final firstLib = tester.getRect(find.byKey(const ValueKey('library-1')));
        final fourthLib = tester.getRect(find.byKey(const ValueKey('library-4')));
        expect(firstLib.top, closeTo(fourthLib.top, 1));

        // Switch to History tab via rail: multi-column grid.
        await tester.tap(find.byKey(const ValueKey('rail-tab-3')));
        await frames(tester);
        expect(store.tab, 3);
        expect(find.byKey(const ValueKey('history-grid')), findsOneWidget);

        // Switch to Search tab via rail: 4 browse cards on a single row.
        await tester.tap(find.byKey(const ValueKey('rail-tab-4')));
        await frames(tester);
        expect(store.tab, 4);
        final seasonalCat = tester.getRect(find.text(store.t('seasonal')).last);
        final favoritesCat = tester.getRect(
          find.text(store.t('favorites')).last,
        );
        expect(seasonalCat.top, closeTo(favoritesCat.top, 1));
        expect(seasonalCat.left, lessThan(favoritesCat.left));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'live window resize transitions cleanly across Slide Over, Split View and full iPad landscape',
    (tester) async {
      final (store, _) = await launchApp(
        tester,
        size: const Size(320, 850),
      );
      store.selectTab(2);
      await frames(tester);
      expect(find.byKey(const ValueKey('main-tab-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('main-navigation-rail')), findsNothing);

      // Expand to iPad portrait / medium Split View.
      tester.view.physicalSize = const Size(744, 1133);
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: BahaPlusApp(store: store, mountPortal: false),
        ),
      );
      await frames(tester);
      expect(store.tab, 2);
      expect(find.byKey(const ValueKey('main-tab-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('main-navigation-rail')), findsNothing);

      // Expand to full iPad landscape.
      tester.view.physicalSize = const Size(1180, 820);
      await frames(tester);
      expect(store.tab, 2);
      expect(find.byKey(const ValueKey('main-navigation-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('main-tab-bar')), findsNothing);

      // Shrink back to Slide Over compact width.
      tester.view.physicalSize = const Size(320, 850);
      await frames(tester);
      expect(store.tab, 2);
      expect(find.byKey(const ValueKey('main-tab-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('main-navigation-rail')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'DetailPage uses a two-column split body and poster hero on expanded tablet screens',
    (tester) async {
      final (store, _) = await launchApp(
        tester,
        size: const Size(1180, 820),
      );
      final anime = store.catalog.items.first;
      store.detail = sampleDetail();
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MaterialApp(home: DetailPage(store: store, anime: anime)),
        ),
      );
      await frames(tester);

      expect(find.byKey(const ValueKey('detail-split-body')), findsOneWidget);
      final episodesRect = tester.getRect(find.text(store.t('episodes')));
      final ratingRect = tester.getRect(find.text(store.t('ratingTitle')));
      expect(episodesRect.left, lessThan(ratingRect.left));
      expect(episodesRect.top, closeTo(ratingRect.top, 20));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'PlayerPage uses split theater layout on landscape tablets, preserves video surface across rotation, and does not force landscape orientation on tablets',
    (tester) async {
      final orientationCalls = <List<String>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationCalls.add((call.arguments as List).cast<String>());
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final store = (await tester.runAsync(
        () => AppStore.create(
          nativeHttpApiFactory: PendingNativeHttpApi.new,
          metadataApi: FakeMetadata(),
          accountApi: FakeAccountApi()
            ..communityResponse = commentPageJson(id: '1'),
          storage: MemoryStorage(),
          animeSearch: FakeSearch(),
        ),
      ))!;
      addTearDown(store.dispose);
      final portal = FakePortal()..communityResponse = commentPageJson(id: '1');
      await store.attach(portal);
      addTearDown(() => store.detach(portal));

      final anime = sampleCatalog().items.first;
      await playFixture(
        store,
        anime,
        onCommand: (action, value) =>
            portal.recordPlayerCommand(store.operation.id, action, value),
      );
      store
        ..playerDetail = sampleDetail()
        ..playback.value = const PlaybackState(
          phase: PlaybackPhase.content,
          surfaceReady: true,
          paused: false,
          duration: 1440,
          position: 120,
          hasDanmaku: true,
        );

      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MaterialApp(
            home: PlayerPage(
              store: store,
              video: const _StatefulVideoFixture(
                key: ValueKey('tablet-video-fixture'),
              ),
            ),
          ),
        ),
      );
      await frames(tester);

      // Expanded landscape tablet shows split theater layout.
      expect(find.byKey(const ValueKey('player-split-layout')), findsOneWidget);
      final videoFinder = find.byKey(const ValueKey('tablet-video-fixture'));
      final videoState = tester.state(videoFinder);
      final videoRect = tester.getRect(videoFinder);
      final episodesRect = tester.getRect(find.text(store.t('episodes')));
      expect(videoRect.right, lessThan(episodesRect.left));

      // Opening danmaku settings on tablet uses a centered modal sheet.
      showDanmakuPanel(tester.element(find.byType(PlayerPage)), store);
      await frames(tester);
      expect(find.byKey(const ValueKey('tablet-modal-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('danmaku-panel')), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(store.t('close')).last);
      await frames(tester);
      expect(find.byKey(const ValueKey('danmaku-panel')), findsNothing);

      // Rotate to iPad portrait: switches to single-column while preserving video State.
      tester.view.physicalSize = const Size(820, 1180);
      await frames(tester);
      expect(find.byKey(const ValueKey('player-split-layout')), findsNothing);
      expect(tester.state(videoFinder), same(videoState));

      // Enter fullscreen on tablet portrait: allows all orientations (does not force landscape lock).
      orientationCalls.clear();
      store.setPlayerFullscreen(true);
      await frames(tester);
      expect(tester.state(videoFinder), same(videoState));
      expect(orientationCalls, isNotEmpty);
      expect(
        orientationCalls.last,
        contains('DeviceOrientation.portraitUp'),
      );

      // Exit fullscreen and rotate back to landscape: video State stays identical.
      store.setPlayerFullscreen(false);
      tester.view.physicalSize = const Size(1180, 820);
      await frames(tester);
      expect(find.byKey(const ValueKey('player-split-layout')), findsOneWidget);
      expect(tester.state(videoFinder), same(videoState));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'secondary pages center readable columns and avoid overflow on tablets with large text',
    (tester) async {
      const tabletSize = Size(1280, 800);
      final (store, portal) = await launchApp(
        tester,
        size: tabletSize,
        textScale: 1.5,
      );
      portal.accountApi.communityResponse = {
        'ok': true,
        'owner': 'reader',
        'items': [notificationJson('20'), notificationJson('21')],
      };

      Future<void> mountPage(Widget page) async {
        await tester.pumpWidget(
          LiquidGlassWidgets.wrap(
            brightnessResolver: Theme.maybeBrightnessOf,
            theme: GlassThemeData.simple(quality: GlassQuality.standard),
            child: MediaQuery(
              data: const MediaQueryData(
                size: tabletSize,
                textScaler: TextScaler.linear(1.5),
              ),
              child: MaterialApp(home: page),
            ),
          ),
        );
        await frames(tester);
        expect(tester.takeException(), isNull);
      }

      await mountPage(SeasonalPage(store: store, openDetail: (_) {}));
      expect(find.byKey(const ValueKey('timeline-1')), findsOneWidget);

      await mountPage(NotificationsPage(store: store));
      final notifHeader = tester.getRect(
        find.descendant(
          of: find.byType(GlassLargeTitle),
          matching: find.text(store.t('notifications')),
        ),
      );
      expect(notifHeader.left, greaterThan(150));

      portal.accountApi.communityResponse = commentPageJson(id: '1');
      await mountPage(
        CommentsPage(
          store: store,
          videoId: '20',
          title: '平板測試動畫',
          rating: sampleDetail().rating,
        ),
      );
      final commentCard = tester.getRect(find.byKey(const ValueKey('comment-1')));
      expect(commentCard.left, greaterThan(150));
      expect(commentCard.right, lessThan(tabletSize.width - 150));

      await mountPage(
        SynopsisPage(
          store: store,
          title: '平板測試動畫',
          description: sampleDetail().description,
        ),
      );
      final synopsisTitle = tester.getRect(find.text('平板測試動畫'));
      expect(synopsisTitle.left, greaterThan(200));

      await mountPage(DiagnosticsPage(store: store));
      final diagCard = tester.getRect(
        find.text(store.t('diagnosticsStopped')),
      );
      expect(diagCard.left, greaterThan(200));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
