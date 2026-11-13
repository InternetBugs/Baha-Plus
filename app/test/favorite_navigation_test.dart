import 'fake_metadata.dart';
import 'dart:async';
import 'package:baha_plus/core/community.dart';
import 'dart:convert';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

const _profile = {'id': 'fixture-user', 'displayName': '測試帳號'};

class _Browser extends StatefulWidget {
  const _Browser({required this.store, super.key});
  final AppStore store;

  @override
  State<_Browser> createState() => _BrowserState();
}

class _BrowserState extends State<_Browser> {
  @override
  Widget build(BuildContext context) => Material(
    child: SafeArea(
      child: Column(
        children: [
          const Text('Official favorite session'),
          TextButton(
            key: const ValueKey('browser-close'),
            onPressed: widget.store.closeBrowser,
            child: const Text('Close official session'),
          ),
        ],
      ),
    ),
  );
}

typedef _Session = ({
  AppStore store,
  FakePortal portal,
  GlobalKey<_BrowserState> browserKey,
});

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<_Session> _launch(
  WidgetTester tester, {
  bool saved = false,
  String filter = 'season',
  int tab = 2,
  ValueNotifier<int>? parentRevision,
}) async {
  tester.view.physicalSize = const Size(400, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final portal = FakePortal();
  final store = (await tester.runAsync(
    () => AppStore.create(
      metadataApi: FakeMetadata(),
      accountApi: portal.accountApi,
      storage: MemoryStorage(),
      animeSearch: FakeSearch(),
    ),
  ))!;
  addTearDown(store.dispose);
  (store.metadataApi as FakeMetadata).detailLoader = (animeId, videoId) async =>
      AnimeDetail.fromJson({
        'title': 'Favorite Anime $animeId',
        'description': 'Official synopsis.',
        'episodes': [
          {'id': videoId, 'label': '1'},
        ],
        'metadata': [
          for (var index = 0; index < 20; index++)
            {'label': 'Metadata $index', 'value': 'Official value $index'},
        ],
      });
  store.catalog = Catalog(
    items: [
      for (var index = 1; index <= 30; index++)
        Anime(
          id: '$index',
          title: 'Favorite Anime $index',
          cover: 'https://p2.bahamut.com.tw/$index.jpg',
          latestVideoId: '${100 + index}',
          sections: const ['season'],
          updateDate: '2026-11-09',
        ),
    ],
  );
  store.accountProfile = AccountProfile.fromJson(_profile);
  store.accountSynced = true;
  if (saved) store.favorites = [...store.catalog.items];
  store.selectTab(tab, filter: filter);
  if (tab == 2) store.query = 'Favorite';
  portal.accountApi.favoriteHandler = (_, _) async {};
  await store.attach(portal);
  store.updateNavigation(OfficialSite.home, canGoBack: false);
  store.navigationFailed();
  final browserKey = GlobalKey<_BrowserState>();
  final revision = parentRevision ?? ValueNotifier(0);
  if (parentRevision == null) addTearDown(revision.dispose);
  await tester.pumpWidget(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      theme: GlassThemeData.simple(quality: GlassQuality.standard),
      child: MaterialApp(
        builder: (context, child) => DefaultTextStyle(
          style: const TextStyle(fontSize: 16, color: Colors.black),
          child: CupertinoTheme(
            data: const CupertinoThemeData(
              textTheme: CupertinoTextThemeData(
                textStyle: TextStyle(fontSize: 16, color: Colors.black),
              ),
            ),
            child: child!,
          ),
        ),
        home: ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (context, value, child) => AppRoot(
            store: store,
            portalBuilder: (_) => _Browser(key: browserKey, store: store),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  return (store: store, portal: portal, browserKey: browserKey);
}

Future<void> _send(
  AppStore store,
  Json body, {
  String? requestId,
  Uri? source,
  Uri? origin,
  bool isMainFrame = true,
}) => store.receive(
  jsonEncode({...body, 'requestId': requestId ?? store.operation.id}),
  origin: origin ?? OfficialSite.home,
  source: source ?? store.browserUri ?? OfficialSite.home,
  isMainFrame: isMainFrame,
);

Future<void> _finishDetail(AppStore store) => _send(store, {
  'type': 'detail',
  'id': store.selectedAnime!.id,
  'detail': {
    'title': store.selectedAnime!.title,
    'description': 'Official synopsis.',
    'episodes': [
      {'id': store.selectedAnime!.latestVideoId, 'label': '1'},
    ],
    'metadata': [
      for (var index = 0; index < 20; index++)
        {'label': 'Metadata $index', 'value': 'Official value $index'},
    ],
  },
});

Future<ScrollController> _openLibraryDetail(
  WidgetTester tester,
  AppStore store,
) async {
  final controller = tester
      .widget<CustomScrollView>(find.byType(CustomScrollView))
      .controller!;
  await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
  await _frames(tester);
  await tester.ensureVisible(find.byKey(const ValueKey('library-5')));
  await _frames(tester);
  expect(controller.offset, greaterThan(0));
  await tester.tap(find.byKey(const ValueKey('library-5')));
  await _frames(tester);
  await _finishDetail(store);
  await _frames(tester);
  return controller;
}

Finder _favoriteButton(AppStore store) => find.descendant(
  of: find.byType(DetailPage),
  matching: find.bySemanticsLabel(
    store.t(store.isFavorite(store.selectedAnime!) ? 'unsave' : 'save'),
  ),
);

void main() {
  testWidgets(
    'parent rebuild preserves routes without rebuilding the overlay during build',
    (tester) async {
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
      final session = await _launch(tester, parentRevision: revision);
      await _openLibraryDetail(tester, session.store);
      final root = tester.element(find.byType(AppRoot, skipOffstage: false));
      final detail = tester.element(find.byType(DetailPage));
      revision.value++;
      await _frames(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester.element(find.byType(AppRoot, skipOffstage: false)),
        same(root),
      );
      expect(tester.element(find.byType(DetailPage)), same(detail));
    },
  );

  for (final saved in [false, true]) {
    testWidgets(
      '${saved ? 'removing' : 'adding'} a native favorite preserves detail and source scroll',
      (tester) async {
        final session = await _launch(
          tester,
          saved: saved,
          filter: saved ? 'favorites' : 'season',
        );
        final store = session.store;
        final source = await _openLibraryDetail(tester, store);
        final offset = source.offset;
        final element = tester.element(find.byType(DetailPage));
        final route = ModalRoute.of(element)!;
        final detail = store.detail;
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(DetailPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scroll.position.jumpTo(80);
        await _frames(tester);
        final detailOffset = scroll.position.pixels;
        final anime = store.selectedAnime!;
        final operation = store.operation;
        final visits = session.portal.visited.length;
        await tester.tap(_favoriteButton(store));
        await _frames(tester);
        expect(store.isFavorite(anime), !saved);
        expect(session.portal.accountApi.favoriteRequests, [
          (anime.id, !saved),
        ]);
        expect(store.operation, same(operation));
        expect(session.portal.visited.length, visits);
        expect(store.browserVisible, isFalse);
        expect(session.browserKey.currentState, isNull);
        expect(tester.element(find.byType(DetailPage)), same(element));
        expect(route.isCurrent, isTrue);
        expect(store.detail, same(detail));
        expect(scroll.position.pixels, detailOffset);
        expect(store.tab, 2);
        expect(store.libraryFilter, saved ? 'favorites' : 'season');
        expect(store.query, 'Favorite');
        expect(source.offset, offset);
        await tester.tap(find.bySemanticsLabel(store.t('close')));
        await _frames(tester);
        expect(source.offset, offset);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'native favorite rejection and obsolete bridge messages preserve confirmed state',
    (tester) async {
      final session = await _launch(tester);
      final store = session.store;
      session.portal.accountApi.favoriteHandler = (_, _) async =>
          throw const CommunityException('rejected');
      await _openLibraryDetail(tester, store);
      final element = tester.element(find.byType(DetailPage));
      final anime = store.selectedAnime!;
      await tester.tap(_favoriteButton(store));
      await _frames(tester);
      expect(store.notice, store.t('accountSyncError'));
      expect(store.isFavorite(anime), isFalse);
      await _send(store, {
        'type': 'favorite-complete',
        'id': anime.id,
        'saved': true,
      });
      expect(store.isFavorite(anime), isFalse);
      expect(store.browserVisible, isFalse);
      expect(tester.element(find.byType(DetailPage)), same(element));
      session.portal.accountApi.favoriteHandler = (_, _) async {};
      await store.toggleFavorite(anime);
      expect(store.isFavorite(anime), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'favorite submissions deduplicate while the native request is pending',
    (tester) async {
      final session = await _launch(tester);
      final store = session.store;
      await _openLibraryDetail(tester, store);
      final pending = Completer<void>();
      session.portal.accountApi.favoriteHandler = (_, _) => pending.future;
      final first = store.toggleFavorite(store.selectedAnime!);
      await store.toggleFavorite(store.selectedAnime!);
      expect(session.portal.accountApi.favoriteRequests, hasLength(1));
      pending.complete();
      await first;
      expect(store.isFavorite(store.selectedAnime!), isTrue);
      expect(store.needsOfficialPortal, isFalse);
    },
  );

  testWidgets(
    'expired login opens above detail and Back cancels the pending favorite',
    (tester) async {
      final session = await _launch(tester);
      final store = session.store;
      final source = await _openLibraryDetail(tester, store);
      final offset = source.offset;
      final element = tester.element(find.byType(DetailPage));
      final route = ModalRoute.of(element)!;
      session.portal.accountApi.favoriteHandler = (_, _) async =>
          throw const CommunityException('login');
      await tester.tap(_favoriteButton(store));
      await _frames(tester);
      expect(store.favoriteLoginPending, isTrue);
      expect(store.browserVisible, isTrue);
      expect(
        find.text('Official favorite session').hitTestable(),
        findsOneWidget,
      );
      expect(route.isCurrent, isFalse);
      expect(route.isActive, isTrue);
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(store.favoriteLoginPending, isFalse);
      expect(store.browserVisible, isFalse);
      expect(route.isCurrent, isTrue);
      expect(tester.element(find.byType(DetailPage)), same(element));
      expect(source.offset, offset);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'login resumes the requested removal without changing detail or source route',
    (tester) async {
      final session = await _launch(tester, saved: true, filter: 'favorites');
      final store = session.store;
      final source = await _openLibraryDetail(tester, store);
      final offset = source.offset;
      final element = tester.element(find.byType(DetailPage));
      final anime = store.selectedAnime!;
      session.portal.accountApi.favoriteHandler = (_, _) async =>
          throw const CommunityException('login');
      session.portal.accountApi.accountLoader = () async => {
        'profile': _profile,
        'favorites': store.catalog.items.map((item) => item.toJson()).toList(),
        'history': [],
      };
      await tester.tap(_favoriteButton(store));
      await _frames(tester);
      expect(store.favoriteLoginPending, isTrue);
      session.portal.accountApi.favoriteHandler = (_, _) async {};
      await _send(store, {
        'type': 'account-authenticated',
        'profile': _profile,
      }, source: OfficialSite.home.resolve('mygather.php'));
      await _frames(tester);
      expect(session.portal.accountApi.favoriteRequests, [
        (anime.id, false),
        (anime.id, false),
      ]);
      expect(store.isFavorite(anime), isFalse);
      expect(store.browserVisible, isFalse);
      expect(store.favoriteLoginPending, isFalse);
      expect(tester.element(find.byType(DetailPage)), same(element));
      expect(ModalRoute.of(element)!.isCurrent, isTrue);
      expect(source.offset, offset);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native favorite keeps the current player, media clock and authorization document',
    (tester) async {
      final session = await _launch(tester);
      final store = session.store;
      final anime = store.catalog.items.first;
      await store.play(anime);
      final document = store.operation;
      store.nativePlaybackDocument = document.id;
      final playback = const PlaybackState(
        phase: PlaybackPhase.content,
        surfaceReady: true,
        duration: 1200,
        position: 42,
      );
      store.playback.value = playback;
      final visits = session.portal.visited.length;
      await store.toggleFavorite(anime);
      expect(store.isFavorite(anime), isTrue);
      expect(store.operation, same(document));
      expect(store.nativePlaybackDocument, document.id);
      expect(store.playback.value, same(playback));
      expect(session.portal.visited.length, visits);
      await store.closeBrowser();
      await _frames(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
