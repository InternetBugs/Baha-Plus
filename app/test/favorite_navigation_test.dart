import 'dart:convert';
import 'package:baha_plus/core/browser_request.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:baha_plus/ui/seasonal_page.dart';
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
}) async {
  tester.view.physicalSize = const Size(400, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = (await tester.runAsync(
    () => AppStore.create(storage: MemoryStorage(), animeSearch: FakeSearch()),
  ))!;
  addTearDown(store.dispose);
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
  final portal = FakePortal();
  await store.attach(portal);
  store.updateNavigation(OfficialSite.home, canGoBack: false);
  store.navigationFailed();
  final browserKey = GlobalKey<_BrowserState>();
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
          portalBuilder: (_) => _Browser(key: browserKey, store: store),
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
  for (final saved in [false, true]) {
    testWidgets(
      '${saved ? 'removing' : 'adding'} a favorite preserves detail, source tab, filter, query and scroll',
      (tester) async {
        final session = await _launch(
          tester,
          saved: saved,
          filter: saved ? 'favorites' : 'season',
        );
        final store = session.store;
        final source = await _openLibraryDetail(tester, store);
        final sourcePosition = source.position;
        final sourceOffset = source.offset;
        final detailElement = tester.element(find.byType(DetailPage));
        final detailRoute = ModalRoute.of(detailElement)!;
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
        final visibility = <bool>[];
        store.addListener(() => visibility.add(store.browserVisible));

        await tester.tap(_favoriteButton(store));
        await _frames(tester);
        final favoriteRequest = store.operation;
        expect(favoriteRequest.intent, BrowserIntent.favorite);
        expect(favoriteRequest.animeId, anime.id);
        expect(favoriteRequest.favoriteTarget, !saved);
        expect(store.browserVisible, isFalse);
        expect(detailRoute.isCurrent, isTrue);
        await store.navigationFinished(OfficialSite.search(anime.title));
        expect(store.busy, isTrue);
        await _send(store, {
          'type': 'favorite-complete',
          'id': anime.id,
          'saved': !saved,
        });
        expect(store.isFavorite(anime), !saved);
        expect(store.operation.intent, BrowserIntent.accountRefresh);
        await _send(store, {
          'type': 'account-synced',
          'profile': _profile,
          'favorites': store.favorites.map((item) => item.toJson()).toList(),
          'history': [],
        });
        await _frames(tester);

        expect(visibility, everyElement(isFalse));
        expect(find.byType(DetailPage), findsOneWidget);
        expect(tester.element(find.byType(DetailPage)), same(detailElement));
        expect(ModalRoute.of(detailElement), same(detailRoute));
        expect(detailRoute.isCurrent, isTrue);
        expect(store.detail, same(detail));
        expect(scroll.position.pixels, detailOffset);
        expect(store.tab, 2);
        expect(store.libraryFilter, saved ? 'favorites' : 'season');
        expect(store.query, 'Favorite');
        expect(source.position, same(sourcePosition));
        expect(source.offset, sourceOffset);
        expect(find.text('Official favorite session'), findsNothing);
        await tester.tap(find.bySemanticsLabel(store.t('close')));
        await _frames(tester);
        expect(find.byType(DetailPage), findsNothing);
        expect(source.offset, sourceOffset);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'favorite failures and late messages leave the detail and confirmed state intact',
    (tester) async {
      final session = await _launch(tester);
      final store = session.store;
      await _openLibraryDetail(tester, store);
      final element = tester.element(find.byType(DetailPage));
      final anime = store.selectedAnime!;
      await tester.tap(_favoriteButton(store));
      await store.navigationFinished(OfficialSite.search(anime.title));
      final request = store.operation.id;
      final valid = {
        'type': 'favorite-complete',
        'id': anime.id,
        'saved': true,
      };
      for (final invalid in [
        {...valid, 'id': '999'},
        {...valid, 'saved': false},
      ]) {
        await _send(store, invalid);
        expect(store.operation.id, request);
        expect(store.isFavorite(anime), isFalse);
      }
      await _send(store, valid, requestId: 'old-request');
      await _send(store, valid, origin: Uri.parse('https://attacker.test/'));
      await _send(store, valid, source: Uri.parse('https://attacker.test/'));
      await _send(store, valid, isMainFrame: false);
      expect(store.operation.id, request);
      expect(store.isFavorite(anime), isFalse);
      await _send(store, {'type': 'favorite-error', 'id': anime.id});
      await _frames(tester);
      expect(store.notice, store.t('accountSyncError'));
      expect(store.browserVisible, isFalse);
      expect(tester.element(find.byType(DetailPage)), same(element));

      await store.toggleFavorite(anime);
      await store.navigationFinished(OfficialSite.search(anime.title));
      final currentRequest = store.operation.id;
      await _send(store, valid, requestId: request);
      expect(store.operation.id, currentRequest);
      expect(store.isFavorite(anime), isFalse);
      await _send(store, valid);
      await _send(store, {'type': 'account-error'});
      await _frames(tester);
      expect(store.isFavorite(anime), isTrue);
      expect(store.accountNeedsRefresh, isTrue);
      expect(store.browserVisible, isFalse);
      expect(tester.element(find.byType(DetailPage)), same(element));
      expect(tester.takeException(), isNull);
    },
  );

  for (final challenge in ['account-guest', 'verification-required']) {
    testWidgets(
      '$challenge presents the same official session above detail and Back returns to it',
      (tester) async {
        final session = await _launch(tester);
        final store = session.store;
        final source = await _openLibraryDetail(tester, store);
        final sourceOffset = source.offset;
        final detailElement = tester.element(find.byType(DetailPage));
        final route = ModalRoute.of(detailElement)!;
        final browser = session.browserKey.currentState;
        await tester.tap(_favoriteButton(store));
        await store.navigationFinished(
          OfficialSite.search(store.selectedAnime!.title),
        );
        final favoriteRequest = store.operation.id;
        await _send(store, {'type': challenge});
        await _frames(tester);
        expect(store.browserVisible, isTrue);
        expect(store.canRetryFavorite, isTrue);
        expect(
          find.text('Official favorite session').hitTestable(),
          findsOneWidget,
        );
        expect(route.isActive, isTrue);
        expect(route.isCurrent, isFalse);
        expect(session.browserKey.currentState, same(browser));
        expect(store.operation.id, favoriteRequest);
        await tester.binding.handlePopRoute();
        await _frames(tester);
        expect(store.browserVisible, isFalse);
        expect(route.isCurrent, isTrue);
        expect(tester.element(find.byType(DetailPage)), same(detailElement));
        expect(session.browserKey.currentState, same(browser));
        expect(source.offset, sourceOffset);
        expect(store.tab, 2);
        expect(store.libraryFilter, 'season');
        expect(store.query, 'Favorite');
        await _send(store, {
          'type': 'favorite-complete',
          'id': store.selectedAnime!.id,
          'saved': true,
        }, requestId: favoriteRequest);
        expect(store.isFavorite(store.selectedAnime!), isFalse);
        // Closing verification can start the ordinary hidden catalog refresh.
        store.navigationFailed();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'login retry preserves the requested removal and returns directly to the original detail',
    (tester) async {
      final session = await _launch(tester, saved: true, filter: 'favorites');
      final store = session.store;
      final source = await _openLibraryDetail(tester, store);
      final offset = source.offset;
      final detailElement = tester.element(find.byType(DetailPage));
      final browser = session.browserKey.currentState;
      final anime = store.selectedAnime!;
      await tester.tap(_favoriteButton(store));
      await store.navigationFinished(OfficialSite.search(anime.title));
      await _send(store, {'type': 'account-guest'});
      await _frames(tester);
      expect(store.favorites, isEmpty);
      expect(store.operation.favoriteTarget, isFalse);
      await store.navigationFinished(
        Uri.parse('https://user.gamer.com.tw/login.php'),
      );
      await store.retryFavorite();
      expect(session.portal.visited.last, OfficialSite.search(anime.title));
      expect(store.operation.favoriteTarget, isFalse);
      await store.navigationFinished(OfficialSite.search(anime.title));
      await _send(store, {
        'type': 'favorite-complete',
        'id': anime.id,
        'saved': false,
      });
      await _send(store, {
        'type': 'account-synced',
        'profile': _profile,
        'favorites': [
          for (final item in store.catalog.items)
            if (item.id != anime.id) item.toJson(),
        ],
        'history': [],
      });
      await _frames(tester);
      expect(store.browserVisible, isFalse);
      expect(store.isFavorite(anime), isFalse);
      expect(tester.element(find.byType(DetailPage)), same(detailElement));
      expect(ModalRoute.of(detailElement)!.isCurrent, isTrue);
      expect(session.browserKey.currentState, same(browser));
      expect(source.offset, offset);
      expect(store.tab, 2);
      expect(store.libraryFilter, 'favorites');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('favorite timeout keeps detail and rejects its expired ticket', (
    tester,
  ) async {
    final session = await _launch(tester);
    final store = session.store;
    await _openLibraryDetail(tester, store);
    final element = tester.element(find.byType(DetailPage));
    final anime = store.selectedAnime!;
    await tester.tap(_favoriteButton(store));
    await store.navigationFinished(OfficialSite.search(anime.title));
    final request = store.operation.id;
    await tester.pump(const Duration(seconds: 31));
    await _send(store, {
      'type': 'favorite-complete',
      'id': anime.id,
      'saved': true,
    }, requestId: request);
    await _frames(tester);
    expect(store.isFavorite(anime), isFalse);
    expect(store.browserVisible, isFalse);
    expect(store.notice, store.t('accountSyncError'));
    expect(tester.element(find.byType(DetailPage)), same(element));
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorite keeps the seasonal route beneath the detail', (
    tester,
  ) async {
    final session = await _launch(tester, tab: 0);
    final store = session.store;
    final heading = find.descendant(
      of: find.byType(SectionHeading),
      matching: find.text(store.t('seasonal')),
    );
    await Scrollable.ensureVisible(tester.element(heading), alignment: .35);
    await _frames(tester);
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: heading, matching: find.byType(SectionHeading)),
        matching: find.byType(CupertinoButton),
      ),
    );
    await _frames(tester);
    final season = tester.state(find.byType(SeasonalPage));
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
    await _frames(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('timeline-5')));
    await _frames(tester);
    final offset = controller.offset;
    await tester.tap(find.byKey(const ValueKey('timeline-5')));
    await _frames(tester);
    await _finishDetail(store);
    await _frames(tester);
    await tester.tap(_favoriteButton(store));
    await store.navigationFinished(
      OfficialSite.search(store.selectedAnime!.title),
    );
    await _send(store, {
      'type': 'favorite-complete',
      'id': store.selectedAnime!.id,
      'saved': true,
    });
    await _send(store, {'type': 'account-error'});
    await _frames(tester);
    await tester.tap(find.bySemanticsLabel(store.t('close')));
    await _frames(tester);
    expect(tester.state(find.byType(SeasonalPage)), same(season));
    expect(controller.offset, offset);
    expect(store.tab, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'player favorite uses a separate validated ticket and preserves the native playback document',
    (tester) async {
      final session = await _launch(tester);
      final store = session.store;
      final anime = store.catalog.items.first;
      await store.play(anime);
      store.updateNavigation(
        OfficialSite.video(anime.latestVideoId!),
        canGoBack: false,
      );
      final document = store.operation;
      const playback = PlaybackState(
        phase: PlaybackPhase.content,
        surfaceReady: true,
        paused: true,
        position: 120,
        duration: 1200,
      );
      store.updateNativePlayback(document.id, playback);
      final navigator = Navigator.of(tester.element(find.byType(AppRoot)));
      navigator.push(
        CupertinoPageRoute<void>(
          builder: (_) => PlayerPage(
            store: store,
            video: const SizedBox(key: ValueKey('test-video-surface')),
          ),
        ),
      );
      await _frames(tester);
      final player = tester.state(find.byType(PlayerPage));
      final loads = session.portal.visited.length;
      await tester.tap(find.bySemanticsLabel(store.t('save')));
      await _frames(tester);
      final script = session.portal.scripts.last;
      final ticket = RegExp(
        r'const favoriteTicket = "([a-f0-9]+)";',
      ).firstMatch(script)!.group(1)!;
      expect(ticket, isNot(document.id));
      expect(script, contains('const documentTicket = "${document.id}"'));
      expect(script, isNot(contains('window.__bahaDocumentNonce =')));
      final completion = {
        'type': 'favorite-complete',
        'id': anime.id,
        'saved': true,
      };
      await _send(store, {...completion, 'saved': false}, requestId: ticket);
      await _send(store, completion, requestId: document.id);
      await _send(
        store,
        completion,
        requestId: ticket,
        source: OfficialSite.video('999'),
      );
      await _send(store, completion, requestId: ticket, isMainFrame: false);
      expect(store.isFavorite(anime), isFalse);
      await _send(store, completion, requestId: ticket);
      await _frames(tester);
      expect(store.isFavorite(anime), isTrue);
      expect(store.operation, same(document));
      expect(store.nativePlaybackDocument, document.id);
      expect(store.playback.value, same(playback));
      expect(store.accountNeedsRefresh, isTrue);
      expect(store.browserVisible, isTrue);
      expect(session.portal.visited.length, loads);
      expect(tester.state(find.byType(PlayerPage)), same(player));
      await tester.tap(find.bySemanticsLabel(store.t('unsave')));
      await _frames(tester);
      final removalTicket = RegExp(
        r'const favoriteTicket = "([a-f0-9]+)";',
      ).firstMatch(session.portal.scripts.last)!.group(1)!;
      expect(removalTicket, isNot(ticket));
      await _send(store, completion, requestId: ticket);
      expect(store.isFavorite(anime), isTrue);
      await _send(store, {
        ...completion,
        'saved': false,
      }, requestId: removalTicket);
      await _frames(tester);
      expect(store.isFavorite(anime), isFalse);
      expect(store.operation, same(document));
      expect(store.nativePlaybackDocument, document.id);
      expect(store.playback.value, same(playback));
      expect(session.portal.visited.length, loads);
      expect(tester.state(find.byType(PlayerPage)), same(player));
      expect(tester.takeException(), isNull);
    },
  );
}
