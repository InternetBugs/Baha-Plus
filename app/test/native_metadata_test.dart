import 'dart:async';

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/app_updates.dart';
import 'package:baha_plus/data/device_storage.dart';
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'fake_account.dart';
import 'fake_metadata.dart';

const _anime = Anime(
  id: '10',
  title: 'Native metadata show',
  cover: 'https://p2.bahamut.com.tw/episode.jpg',
  latestVideoId: '20',
  sections: ['season', 'hot'],
);

Catalog _catalog([Anime anime = _anime]) =>
    Catalog(items: [anime], fetchedAt: '2026-11-13T00:00:00Z');

AnimeDetail _detail(String title, String videoId) => AnimeDetail.fromJson({
  'title': title,
  'description': 'Native synopsis',
  'episodes': [
    {'id': videoId, 'label': '1'},
  ],
  'metadata': [],
});

class _PortalLifecycle {
  int created = 0, disposed = 0;
  final portal = FakePortal();
}

class _Portal extends StatefulWidget {
  const _Portal(this.store, this.lifecycle);
  final AppStore store;
  final _PortalLifecycle lifecycle;
  @override
  State<_Portal> createState() => _PortalState();
}

class _PortalState extends State<_Portal> {
  @override
  void initState() {
    super.initState();
    widget.lifecycle.created++;
    unawaited(widget.store.attach(widget.lifecycle.portal));
  }

  @override
  void dispose() {
    widget.store.detach(widget.lifecycle.portal);
    widget.lifecycle.disposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Material(child: Center(child: Text('Official operation')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppStore> create(
    FakeMetadata api, {
    MemoryStorage? storage,
    FakeAccountApi? accountApi,
  }) async {
    final store = await AppStore.create(
      storage: storage ?? MemoryStorage(),
      metadataApi: api,
      accountApi: accountApi ?? FakeAccountApi(),
      animeSearch: FakeSearch(),
      updates: AppUpdates(
        versionLoader: () async => '1.0.0',
        client: MockClient((_) async => http.Response('', 404)),
      ),
    );
    addTearDown(store.dispose);
    return store;
  }

  test(
    'native metadata failure is explicit and never navigates or runs JS',
    () async {
      final api = FakeMetadata();
      final store = await create(api);
      final portal = FakePortal();
      await store.attach(portal);
      await store.refreshCatalog();
      await store.openDetail(_anime);
      expect(store.catalogFailed, isTrue);
      expect(store.catalogLoading, isFalse);
      expect(store.detailFailed, isTrue);
      expect(store.detailLoading, isFalse);
      expect(api.catalogRequests, 1);
      expect(api.detailRequests, [(animeId: '10', videoId: '20')]);
      expect(portal.visited, isEmpty);
      expect(portal.scripts, isEmpty);
      expect(store.needsOfficialPortal, isFalse);
    },
  );

  test(
    'successful retry clears errors, caches catalog and leaves account alone',
    () async {
      final api = FakeMetadata();
      final disk = MemoryStorage();
      final store = await create(api, storage: disk);
      await store.refreshCatalog();
      api.catalogLoader = () async => _catalog();
      api.detailLoader = (_, video) async => _detail(_anime.title, video);
      await store.refreshCatalog();
      await store.openDetail(_anime);
      expect(store.catalogFailed, isFalse);
      expect(store.catalog.items.single.id, '10');
      expect((await CatalogCache(disk).load())!.items.single.id, '10');
      expect(store.detailFailed, isFalse);
      expect(store.detail!.episodes.single.id, '20');
      expect(store.history, isEmpty);
      expect(store.favorites, isEmpty);
      expect(store.needsOfficialPortal, isFalse);
    },
  );

  test(
    'failed refresh preserves the existing cache with a visible error',
    () async {
      final api = FakeMetadata()..catalogLoader = () async => _catalog();
      final disk = MemoryStorage();
      final store = await create(api, storage: disk);
      await store.refreshCatalog();
      api.catalogLoader = null;
      await store.refreshCatalog();
      expect(store.catalogFailed, isTrue);
      expect(store.catalog.items.single.id, '10');
      expect((await CatalogCache(disk).load())!.items.single.id, '10');
    },
  );

  test(
    'late catalog and detail responses cannot overwrite a newer request',
    () async {
      final oldCatalog = Completer<Catalog>();
      final oldDetail = Completer<AnimeDetail>();
      final api = FakeMetadata();
      api.catalogLoader = () => oldCatalog.future;
      api.detailLoader = (_, _) => oldDetail.future;
      final store = await create(api);
      final firstCatalog = store.refreshCatalog();
      final firstDetail = store.openDetail(_anime);
      const next = Anime(
        id: '11',
        title: 'Next show',
        cover: 'https://p2.bahamut.com.tw/next.jpg',
        latestVideoId: '21',
      );
      api.catalogLoader = () async => _catalog(next);
      api.detailLoader = (_, video) async => _detail(next.title, video);
      await store.refreshCatalog();
      await store.openDetail(next);
      oldCatalog.complete(_catalog());
      oldDetail.complete(_detail(_anime.title, '20'));
      await Future.wait([firstCatalog, firstDetail]);
      expect(store.catalog.items.single.id, '11');
      expect(store.detail!.title, next.title);
      expect(store.detail!.episodes.single.id, '21');
    },
  );

  test(
    'a detail without video ID retains its existing inert HTML reader',
    () async {
      final store = await create(FakeMetadata());
      final portal = FakePortal();
      await store.attach(portal);
      await store.openDetail(
        const Anime(
          id: '10',
          title: 'No video yet',
          cover: 'https://p2.bahamut.com.tw/poster.jpg',
        ),
      );
      expect(store.needsOfficialPortal, isTrue);
      expect(portal.visited, [OfficialSite.home]);
    },
  );

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> launch(
    WidgetTester tester,
    AppStore store,
    _PortalLifecycle lifecycle,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
          home: AppRoot(
            store: store,
            portalBuilder: (_) => _Portal(store, lifecycle),
          ),
        ),
      ),
    );
    await frames(tester);
  }

  testWidgets(
    'native catalog and video detail never mount an offstage portal',
    (tester) async {
      final api = FakeMetadata();
      api.catalogLoader = () async => _catalog();
      api.detailLoader = (_, video) async => _detail(_anime.title, video);
      final store = (await tester.runAsync(() => create(api)))!;
      final lifecycle = _PortalLifecycle();
      await launch(tester, store, lifecycle);
      expect(lifecycle.created, 0);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('featured-10')),
          matching: find.text(_anime.title),
        ),
      );
      await frames(tester);
      expect(find.byType(DetailPage), findsOneWidget);
      expect(store.detailFailed, isFalse);
      expect(lifecycle.created, 0);
      expect(find.byType(_Portal, skipOffstage: false), findsNothing);
    },
  );

  testWidgets(
    'catalog failure is visible, retry stays native and creates no portal',
    (tester) async {
      final api = FakeMetadata();
      final store = (await tester.runAsync(() => create(api)))!;
      final lifecycle = _PortalLifecycle();
      await launch(tester, store, lifecycle);
      expect(find.text(store.t('catalogUnavailable')), findsOneWidget);
      expect(lifecycle.created, 0);
      api.catalogLoader = () async => _catalog();
      await tester.tap(find.text(store.t('retry')));
      await frames(tester);
      expect(find.text(store.t('catalogUnavailable')), findsNothing);
      expect(store.catalogFailed, isFalse);
      expect(api.catalogRequests, 2);
      expect(lifecycle.created, 0);
    },
  );

  testWidgets(
    'playback portal unmounts after media cleanup while native account sync is pending',
    (tester) async {
      final api = FakeMetadata()..catalogLoader = () async => _catalog();
      final pending = Completer<Json?>();
      final accountApi = FakeAccountApi()..accountLoader = () => pending.future;
      final store = (await tester.runAsync(
        () => create(api, accountApi: accountApi),
      ))!;
      final lifecycle = _PortalLifecycle();
      await launch(tester, store, lifecycle);
      expect(lifecycle.created, 0);
      await store.play(_anime);
      await frames(tester);
      expect(lifecycle.created, 1);
      expect(lifecycle.portal.visited.single, OfficialSite.video('20'));
      final closing = store.closeBrowser();
      await tester.pump();
      expect(lifecycle.disposed, 1);
      expect(store.accountLoading, isTrue);
      expect(store.needsOfficialPortal, isFalse);
      expect(lifecycle.portal.visited, [OfficialSite.video('20')]);
      expect(
        lifecycle.portal.scripts.any(
          (script) => script.contains('account-authenticated'),
        ),
        isFalse,
      );
      pending.complete(null);
      await closing;
      await frames(tester);
      expect(lifecycle.disposed, 1);
      expect(store.needsOfficialPortal, isFalse);
      await store.play(_anime);
      await frames(tester);
      expect(lifecycle.created, 2);
      expect(lifecycle.portal.visited.last, OfficialSite.video('20'));
      await store.closeBrowser();
      await frames(tester);
    },
  );
}
