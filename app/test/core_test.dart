import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:baha_plus/core/browser_request.dart';
import 'package:baha_plus/core/browser_presentation.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/device_storage.dart';
import 'package:baha_plus/data/official_search.dart';

class FakeSearch implements AnimeSearch {
  final queries = <String>[];
  final pending = <String, Completer<List<Anime>>>{};
  List<Anime> results = [];
  List<Anime> recent = [];
  Object? error;
  @override
  Future<List<Anime>> recentSeries() async => recent;
  @override
  Future<List<Anime>> search(String query, {bool useAccount = true}) async {
    queries.add(query);
    if (pending[query] case final response?) return response.future;
    if (error case final failure?) throw failure;
    return results;
  }

  @override
  void dispose() {}
}

class MemoryStorage implements DeviceStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class FakePortal implements OfficialPortal {
  final communityRequests = <Json>[];
  Json communityResponse = {'ok': false, 'code': 'unavailable'};
  Completer<Json>? communityPending;
  Future<Json> Function(String, Json)? communityHandler;
  @override
  Future<Json> community(String action, Json arguments) async {
    communityRequests.add({'action': action, ...arguments});
    if (communityHandler != null) return communityHandler!(action, arguments);
    return communityPending?.future ?? communityResponse;
  }

  final visited = <Uri>[];
  final scripts = <String>[];
  final publicRequests = <Uri>[];
  final publicRequestAccounts = <bool>[];
  Json publicResponse = {
    'data': {'animeList': []},
  };
  @override
  Future<Json> fetchPublicCatalog(Uri uri, {required bool useAccount}) async {
    publicRequests.add(uri);
    publicRequestAccounts.add(useAccount);
    return publicResponse;
  }

  @override
  Future<void> load(Uri uri) async => visited.add(uri);
  @override
  Future<dynamic> evaluate(String script) async {
    scripts.add(script);
    return true;
  }

  @override
  Future<void> goBack() async {}
  @override
  Future<void> reload() async {}
}

Future<AppStore> _createStore({
  DeviceStorage? storage,
  AnimeSearch? animeSearch,
}) => AppStore.create(
  storage: storage ?? MemoryStorage(),
  animeSearch: animeSearch ?? FakeSearch(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture =
      jsonDecode(File('test/fixtures/catalog.json').readAsStringSync()) as Json;
  final catalog = Catalog.fromJson(fixture);

  Json playerState({String phase = 'content'}) => {
    'type': 'player-state',
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
  };

  test(
    'playback bridge binds state to the exact series, episode and document',
    () {
      final request = BrowserRequest(
        intent: BrowserIntent.play,
        animeId: '10',
        videoId: '20',
      );
      Json? accept(Json body, {String video = '20'}) => request.accept(
        jsonEncode({...body, 'requestId': request.id}),
        origin: OfficialSite.home,
        source: OfficialSite.video(video),
        isMainFrame: true,
      );
      expect(accept(playerState()), isNotNull);
      expect(accept({...playerState(), 'id': '11'}), isNull);
      expect(accept({...playerState(), 'videoId': '21'}, video: '21'), isNull);
      expect(accept(playerState(), video: '21'), isNull);
      expect(accept({...playerState(), 'position': -1}), isNull);
      expect(accept({...playerState(), 'rate': 10}), isNull);
      expect(
        accept({
          ...playerState(),
          'qualities': [720, 720],
        }),
        isNull,
      );
      expect(
        accept({
          ...playerState(),
          'qualities': [720],
          'quality': 1080,
        }),
        isNull,
      );
      expect(
        PlaybackState.fromJson(playerState(phase: 'age')).canControl,
        isFalse,
      );
      expect(
        PlaybackState.fromJson(playerState(phase: 'advertisement')).canControl,
        isFalse,
      );
    },
  );

  test(
    'player metadata updates preserve the active playback operation',
    () async {
      final store = await _createStore(storage: MemoryStorage());
      addTearDown(store.dispose);
      final portal = FakePortal();
      await store.attach(portal);
      final anime = Anime(
        id: '10',
        title: 'Test',
        cover: 'https://p2.bahamut.com.tw/10.jpg',
        latestVideoId: '20',
      );
      await store.play(anime);
      final request = store.operation;
      Future<void> send(Json body) => store.receive(
        jsonEncode({...body, 'requestId': request.id}),
        origin: OfficialSite.home,
        source: OfficialSite.video('20'),
        isMainFrame: true,
      );
      await send({
        'type': 'player-detail',
        'id': '10',
        'videoId': '20',
        'detail': {
          'title': 'Test',
          'description': 'Synopsis',
          'episodes': [
            {'id': '20', 'label': '1'},
          ],
          'metadata': [],
        },
      });
      await send(playerState());
      expect(store.showsPlayer, isTrue);
      expect(store.operation.id, request.id);
      expect(store.playerDetail?.episodes.single.id, '20');
      expect(store.playback.value.position, 37);
      await store.controlPlayer('seek', 42);
      expect(portal.scripts.last, contains('"seek",42.0'));
      await send(playerState(phase: 'advertisement'));
      final count = portal.scripts.length;
      await store.controlPlayer('seek', 100);
      expect(portal.scripts.length, count);
    },
  );

  test(
    'background playback stays paused across a new document and foreground return',
    () async {
      final store = await _createStore(storage: MemoryStorage());
      addTearDown(store.dispose);
      final portal = FakePortal();
      await store.attach(portal);
      final idleCount = portal.scripts.length;
      await store.setApplicationActive(false);
      expect(portal.scripts.length, idleCount);
      await store.setApplicationActive(true);
      const anime = Anime(
        id: '10',
        title: 'Test',
        cover: 'https://p2.bahamut.com.tw/10.jpg',
        latestVideoId: '20',
      );
      await store.play(anime);
      await store.receive(
        jsonEncode({...playerState(), 'requestId': store.operation.id}),
        origin: OfficialSite.home,
        source: OfficialSite.video('20'),
        isMainFrame: true,
      );
      await store.setApplicationActive(false);
      expect(
        portal.scripts.last,
        contains('window.__bahaMediaSuspended = true'),
      );
      expect(portal.scripts.last, contains('media.pause()'));
      expect(portal.scripts.last, contains(store.operation.id));
      final count = portal.scripts.length;
      await store.controlPlayer('play');
      expect(portal.scripts.length, count);
      await store.navigationFinished(OfficialSite.video('20'));
      final configuration = portal.scripts[portal.scripts.length - 2];
      expect(configuration, contains('window.__bahaMediaSuspended = true'));
      expect(configuration, contains('media.pause()'));
      await store.setApplicationActive(true);
      expect(
        portal.scripts.last,
        contains('window.__bahaMediaSuspended = false'),
      );
      expect(portal.scripts.last, isNot(contains('.play(')));
      await store.controlPlayer('play');
      expect(portal.scripts.last, contains('"play"'));
    },
  );

  test(
    'account sync returns from the login site to the official account origin',
    () async {
      final store = await _createStore(storage: MemoryStorage());
      addTearDown(store.dispose);
      final portal = FakePortal();
      await store.attach(portal);
      await store.connectAccount();
      store.updateNavigation(
        Uri.parse('https://user.gamer.com.tw/login.php'),
        canGoBack: true,
      );
      final before = portal.scripts.length;
      await store.syncAccount();
      expect(portal.visited.last, OfficialSite.home.resolve('mygather.php'));
      expect(store.browserVisible, isTrue);
      expect(store.operation.intent, BrowserIntent.account);
      expect(
        portal.scripts
            .skip(before)
            .any((script) => script.contains("post({type:'account-guest'})")),
        isFalse,
      );
      await store.navigationFinished(OfficialSite.home.resolve('mygather.php'));
      expect(store.operation.intent, BrowserIntent.accountRefresh);
      expect(portal.scripts.last, contains("post({type:'account-guest'})"));
    },
  );

  test(
    'login reload replaces the old sync request and starts sync in the new document',
    () async {
      final store = await _createStore();
      addTearDown(store.dispose);
      store.catalog = catalog;
      final portal = FakePortal();
      await store.attach(portal);
      await store.connectAccount();
      final account = OfficialSite.home.resolve('mygather.php');
      await store.navigationFinished(account);
      final oldRequest = store.operation.id;
      await store.receive(
        jsonEncode({'type': 'account-guest', 'requestId': oldRequest}),
        origin: OfficialSite.home,
        source: account,
        isMainFrame: true,
      );
      expect(store.busy, isFalse);
      store.navigationStarted();
      final newRequest = store.operation.id;
      expect(newRequest, isNot(oldRequest));
      expect(store.busy, isTrue);
      await store.receive(
        jsonEncode({'type': 'account-guest', 'requestId': oldRequest}),
        origin: OfficialSite.home,
        source: account,
        isMainFrame: true,
      );
      expect(store.busy, isTrue);
      final before = portal.scripts.length;
      await store.navigationFinished(account);
      expect(portal.scripts.length, before + 1);
      expect(portal.scripts.last, contains('const watch = true'));
      expect(portal.scripts.last, isNot(contains('__BAHA_WATCH_ACCOUNT__')));
      expect(store.operation.id, isNot(newRequest));
    },
  );

  test(
    'identified login survives a failed data sync and clears another account snapshot',
    () async {
      final disk = MemoryStorage();
      final store = await _createStore(storage: disk);
      addTearDown(store.dispose);
      store.catalog = catalog;
      final portal = FakePortal();
      await store.attach(portal);
      store.updateNavigation(OfficialSite.home, canGoBack: false);
      Future<void> send(Json body) => store.receive(
        jsonEncode({...body, 'requestId': store.operation.id}),
        origin: OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: true,
      );
      await store.syncAccount();
      await send({
        'type': 'account-synced',
        'profile': {'id': 'old-user', 'displayName': '舊帳號'},
        'favorites': [catalog.items.first.toJson()],
        'history': [],
      });
      await store.syncAccount();
      final request = store.operation.id;
      store.browserVisible = true;
      await send({
        'type': 'account-authenticated',
        'profile': {'id': 'new-user', 'displayName': '新帳號'},
      });
      expect(store.operation.id, request);
      expect(store.busy, isTrue);
      expect(store.browserVisible, isFalse);
      expect(store.accountProfile?.id, 'new-user');
      expect(store.favorites, isEmpty);
      expect(store.history, isEmpty);
      expect(store.accountSynced, isFalse);
      await send({'type': 'account-error'});
      expect(store.busy, isFalse);
      expect(store.accountProfile?.id, 'new-user');
      expect(store.accountNeedsRefresh, isTrue);
      expect(store.notice, store.t('accountSyncError'));
      await Future<void>.delayed(Duration.zero);
      expect(await AccountCache(disk).load(), isNull);

      await store.syncAccount();
      await send({'type': 'account-guest'});
      expect(store.accountProfile, isNull);
      expect(store.accountNeedsRefresh, isFalse);
    },
  );

  test(
    'same account keeps its last synced data when refresh fails after login identification',
    () async {
      final store = await _createStore();
      addTearDown(store.dispose);
      store.catalog = catalog;
      await store.attach(FakePortal());
      store.updateNavigation(OfficialSite.home, canGoBack: false);
      Future<void> send(Json body) => store.receive(
        jsonEncode({...body, 'requestId': store.operation.id}),
        origin: OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: true,
      );
      const profile = {'id': 'fixture-user', 'displayName': '測試暱稱'};
      await store.syncAccount();
      await send({
        'type': 'account-synced',
        'profile': profile,
        'favorites': [catalog.items.first.toJson()],
        'history': [],
      });
      await store.syncAccount();
      await send({'type': 'account-authenticated', 'profile': profile});
      await send({'type': 'account-error'});
      expect(store.accountProfile?.id, 'fixture-user');
      expect(store.accountSynced, isTrue);
      expect(store.favorites.single.id, catalog.items.first.id);
      expect(store.accountNeedsRefresh, isTrue);
    },
  );

  test(
    'account identity events require a current trusted account request and valid profile',
    () {
      final request = BrowserRequest(intent: BrowserIntent.accountRefresh);
      final body = {
        'type': 'account-authenticated',
        'requestId': request.id,
        'profile': {'id': 'fixture-user', 'displayName': '測試暱稱'},
      };
      Json? accept(Json value, {Uri? origin}) => request.accept(
        jsonEncode(value),
        origin: origin ?? OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: true,
      );
      expect(accept(body), isNotNull);
      expect(accept({...body, 'requestId': 'expired'}), isNull);
      expect(accept({...body, 'profile': null}), isNull);
      expect(
        accept(body, origin: Uri.parse('https://user.gamer.com.tw/')),
        isNull,
      );
      expect(
        BrowserRequest(intent: BrowserIntent.browse, id: request.id).accept(
          jsonEncode(body),
          origin: OfficialSite.home,
          source: OfficialSite.home,
          isMainFrame: true,
        ),
        isNull,
      );
    },
  );

  test(
    'account data updates automatically on history entry and foreground without duplicate requests',
    () async {
      final store = await _createStore(storage: MemoryStorage());
      addTearDown(store.dispose);
      store.catalog = catalog;
      final portal = FakePortal();
      await store.attach(portal);
      store.updateNavigation(OfficialSite.home, canGoBack: false);
      Future<void> finish() => store.receive(
        jsonEncode({
          'type': 'account-synced',
          'requestId': store.operation.id,
          'favorites': [],
          'history': [],
        }),
        origin: OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: true,
      );
      await store.syncAccount();
      await finish();
      final before = portal.scripts.length;
      store.selectTab(3);
      expect(portal.scripts.length, before + 1);
      store.selectTab(3);
      await store.syncAccount();
      expect(portal.scripts.length, before + 1);
      await finish();
      await store.setApplicationActive(false);
      await store.setApplicationActive(true);
      expect(portal.scripts.length, before + 2);
      await finish();
      expect(store.accountSynced, isTrue);
    },
  );

  test(
    'closing the login page automatically returns to the official account for hidden sync',
    () async {
      final store = await _createStore(storage: MemoryStorage());
      addTearDown(store.dispose);
      final portal = FakePortal();
      await store.attach(portal);
      await store.connectAccount();
      store.updateNavigation(
        Uri.parse('https://user.gamer.com.tw/login.php'),
        canGoBack: true,
      );
      await store.closeBrowser();
      expect(store.browserVisible, isFalse);
      expect(portal.visited.last, OfficialSite.home.resolve('mygather.php'));
      expect(store.operation.intent, BrowserIntent.accountRefresh);
      await store.navigationFinished(OfficialSite.home.resolve('mygather.php'));
      expect(portal.scripts.last, contains("post({type:'account-guest'})"));
    },
  );

  test(
    'official account profile validates public avatar URLs and clears with the account session',
    () async {
      const profile = {
        'id': 'fixture-user',
        'displayName': '測試暱稱',
        'avatar':
            'https://avatar2.bahamut.com.tw/avataruserpic/f/i/fixture-user/fixture-user.png',
      };
      expect(AccountProfile.fromJson(profile).displayName, '測試暱稱');
      for (final avatar in [
        'https://attacker.test/avatar.png',
        'http://avatar2.bahamut.com.tw/avatar.png',
        'https://user@avatar2.bahamut.com.tw/avatar.png',
      ]) {
        expect(
          () => AccountProfile.fromJson({...profile, 'avatar': avatar}),
          throwsFormatException,
        );
      }
      final disk = MemoryStorage();
      final store = await _createStore(storage: disk);
      addTearDown(store.dispose);
      await store.attach(FakePortal());
      store.updateNavigation(
        OfficialSite.home.resolve('mygather.php'),
        canGoBack: false,
      );
      Future<void> send(Json body) => store.receive(
        jsonEncode({...body, 'requestId': store.operation.id}),
        origin: OfficialSite.home,
        source: OfficialSite.home.resolve('mygather.php'),
        isMainFrame: true,
      );
      await store.syncAccount();
      await send({
        'type': 'account-synced',
        'profile': profile,
        'favorites': [],
        'history': [],
      });
      expect(store.accountProfile?.id, 'fixture-user');
      await Future<void>.delayed(Duration.zero);
      expect(disk.values[AccountCache.key], isNotEmpty);
      await store.syncAccount();
      await send({'type': 'account-guest'});
      expect(store.accountProfile, isNull);
      expect(store.accountSynced, isFalse);
      await store.syncAccount();
      await send({
        'type': 'account-synced',
        'profile': profile,
        'favorites': [],
        'history': [],
      });
      await store.connectAccount();
      expect(store.accountProfile, isNull);
    },
  );

  test(
    'account snapshot restores on restart and clears after official logout',
    () async {
      final disk = MemoryStorage();
      final store = await _createStore(storage: disk);
      addTearDown(store.dispose);
      store.catalog = catalog;
      await store.attach(FakePortal());
      store.updateNavigation(OfficialSite.home, canGoBack: false);
      await store.syncAccount();
      await store.receive(
        jsonEncode({
          'type': 'account-synced',
          'requestId': store.operation.id,
          'profile': {'id': 'fixture-user', 'displayName': '測試暱稱'},
          'favorites': [catalog.items.first.toJson()],
          'history': [
            {
              'anime': catalog.items.first.toJson(),
              'videoId': '20',
              'episodeLabel': '第一集',
              'progress': 0.5,
            },
          ],
        }),
        origin: OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: true,
      );
      await Future<void>.delayed(Duration.zero);
      final restored = await _createStore(storage: disk);
      addTearDown(restored.dispose);
      expect(restored.accountProfile?.id, 'fixture-user');
      expect(restored.accountSynced, isTrue);
      expect(restored.favorites.single.id, catalog.items.first.id);
      expect(restored.history.single.progress, 0.5);

      restored.catalog = catalog;
      await restored.attach(FakePortal());
      restored.updateNavigation(OfficialSite.home, canGoBack: false);
      await restored.syncAccount();
      await restored.receive(
        jsonEncode({
          'type': 'account-guest',
          'requestId': restored.operation.id,
        }),
        origin: OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: true,
      );
      await Future<void>.delayed(Duration.zero);
      final afterLogout = await _createStore(storage: disk);
      addTearDown(afterLogout.dispose);
      expect(afterLogout.accountProfile, isNull);
      expect(afterLogout.accountSynced, isFalse);
      expect(afterLogout.favorites, isEmpty);
      expect(afterLogout.history, isEmpty);

      disk.values[AccountCache.key] = '{"favorites":"invalid"}';
      final damaged = await _createStore(storage: disk);
      addTearDown(damaged.dispose);
      expect(damaged.accountSynced, isFalse);
    },
  );

  test(
    'desktop presentation removes mobile markers but keeps the real engine',
    () {
      const native =
          'Mozilla/5.0 (Linux; Android 15; sdk_gphone64_x86_64 Build/AE3A; wv) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
          'Chrome/124.0.6367.219 Mobile Safari/537.36';
      expect(
        desktopChromiumUserAgent(native),
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.6367.219 Safari/537.36',
      );
      expect(
        desktopChromiumUserAgent(desktopChromiumUserAgent(native)),
        desktopChromiumUserAgent(native),
      );
    },
  );

  test('official navigation and numeric identity remain strict', () {
    expect(OfficialSite.validId('123'), isTrue);
    for (final id in ['', '１２３', '123?redirect=1', '1 2']) {
      expect(OfficialSite.validId(id), isFalse);
    }
    expect(
      OfficialSite.allowedNavigation(
        Uri.parse('https://gamer.com.tw.attacker.test/'),
      ),
      isFalse,
    );
    expect(OfficialSite.trustedOrigin(Uri.parse('about:blank')), isFalse);
    expect(
      OfficialSite.trustedOrigin(Uri.parse('https://ani.gamer.com.tw:8443/')),
      isFalse,
    );
    expect(
      OfficialSite.allowedNavigation(Uri.parse('http://ani.gamer.com.tw/')),
      isFalse,
    );
    expect(
      OfficialSite.allowedNavigation(
        Uri.parse('https://user.gamer.com.tw/login.php'),
      ),
      isTrue,
    );
    expect(OfficialSite.desktopPlayer(OfficialSite.video('20')), isTrue);
    expect(
      OfficialSite.desktopPlayer(OfficialSite.home.resolve('mygather.php')),
      isFalse,
    );
    expect(
      OfficialSite.search('動畫 & 中文').queryParameters['keyword'],
      '動畫 & 中文',
    );
  });

  test(
    'cache starts missing and stores only valid real catalog projections',
    () async {
      final disk = MemoryStorage();
      final cache = CatalogCache(disk);
      expect(await cache.load(), isNull);
      await cache.save(catalog);
      expect((await cache.load())!.encode(), catalog.encode());
      await cache.save(const Catalog());
      expect((await cache.load())!.encode(), catalog.encode());
      disk.values[CatalogCache.key] = '{broken';
      expect(await cache.load(), isNull);
      final forged = jsonDecode(jsonEncode(fixture)) as Json;
      forged['items'][0]['cover'] = 'https://attacker.test/poster.jpg';
      disk.values[CatalogCache.key] = jsonEncode(forged);
      expect(await cache.load(), isNull);
    },
  );

  test(
    'search accepts both scripts, full width, accents and supplementary text',
    () async {
      final store = await _createStore(storage: MemoryStorage());
      addTearDown(store.dispose);
      expect(store.folding.matches('世界最強的魔女，就此開始', '世界最强的魔女'), isTrue);
      expect(
        store.folding.matches('Fate/strange Fake', 'Ｆａｔｅ　ｓｔｒａｎｇｅ'),
        isTrue,
      );
      expect(store.folding.normalize('𠮷-野'), '𠮷野');
      expect(store.folding.normalize('e\u0301'), store.folding.normalize('é'));
      expect(store.folding.toTraditional('进击的巨人'), '進擊的巨人');
    },
  );

  test(
    'bridge requires current nonce, native official origin and main frame',
    () {
      final current = BrowserRequest(intent: BrowserIntent.catalog);
      final valid = {...fixture, 'type': 'catalog', 'requestId': current.id};
      Json? check(Json body, {bool main = true, Uri? origin}) => current.accept(
        jsonEncode(body),
        origin: origin ?? OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: main,
      );
      expect(check(valid), isNotNull);
      expect(check(valid, main: false), isNull);
      expect(check(valid, origin: Uri.parse('https://attacker.test')), isNull);
      expect(check({...valid, 'requestId': 'stale'}), isNull);
      expect(check({...valid, 'items': []}), isNull);
      expect(
        check({
          ...valid,
          'items': [fixture['items'][0], fixture['items'][0]],
        }),
        isNull,
      );
      expect(check({...valid, 'fetchedAt': 'bad'}), isNull);
    },
  );

  test(
    'search replies belong to their exact submitted query and allow no results',
    () {
      final request = BrowserRequest(intent: BrowserIntent.search, query: '動畫');
      final raw = jsonEncode({
        'type': 'search',
        'requestId': request.id,
        'items': [],
        'fetchedAt': fixture['fetchedAt'],
      });
      expect(
        request.accept(
          raw,
          origin: OfficialSite.home,
          source: OfficialSite.search('動畫'),
          isMainFrame: true,
        ),
        isNotNull,
      );
      expect(
        request.accept(
          raw,
          origin: OfficialSite.home,
          source: OfficialSite.search('other'),
          isMainFrame: true,
        ),
        isNull,
      );
    },
  );

  test(
    'favorite completion must confirm the exact series and requested state',
    () {
      final request = BrowserRequest(
        intent: BrowserIntent.favorite,
        animeId: '10',
        favoriteTarget: true,
      );
      Json? check(String id, bool saved) => request.accept(
        jsonEncode({
          'type': 'favorite-complete',
          'requestId': request.id,
          'id': id,
          'saved': saved,
        }),
        origin: OfficialSite.home,
        source: OfficialSite.search('test'),
        isMainFrame: true,
      );
      expect(check('10', true), isNotNull);
      expect(check('11', true), isNull);
      expect(check('10', false), isNull);
    },
  );

  test('invalid history progress is rejected', () {
    for (final progress in [-.01, 1.01, double.nan, double.infinity]) {
      expect(
        () => WatchEntry.fromJson({
          'anime': fixture['items'][0],
          'videoId': '20',
          'episodeLabel': '1',
          'progress': progress,
        }),
        throwsFormatException,
      );
    }
    expect(
      WatchEntry.fromJson({
        'anime': fixture['items'][0],
        'videoId': '20',
        'episodeLabel': '1',
        'progress': .64,
      }).progress,
      .64,
    );
  });

  test(
    'app starts blank, caches successful response and keeps it after failed refresh',
    () async {
      final disk = MemoryStorage();
      final store = await _createStore(storage: disk);
      addTearDown(store.dispose);
      expect(store.catalog.items, isEmpty);
      final portal = FakePortal();
      await store.attach(portal);
      store.updateNavigation(OfficialSite.home, canGoBack: false);
      final request = store.operation;
      await store.receive(
        jsonEncode({...fixture, 'type': 'catalog', 'requestId': request.id}),
        origin: OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: true,
      );
      expect(store.catalog.items.length, catalog.items.length);
      expect(store.catalogSource, 'live');
      store.navigationFailed();
      expect(store.catalog.encode(), catalog.encode());
      final restarted = await _createStore(storage: disk);
      addTearDown(restarted.dispose);
      expect(restarted.catalog.encode(), catalog.encode());
      expect(restarted.catalogSource, 'cache');
      expect(restarted.favorites, isEmpty);
      expect(restarted.history, isEmpty);
      expect(disk.values.keys, [CatalogCache.key]);
    },
  );

  test('new search discards stale asynchronous response', () async {
    final search = FakeSearch();
    search.pending['old'] = Completer<List<Anime>>();
    search.pending['new'] = Completer<List<Anime>>();
    final store = await _createStore(
      storage: MemoryStorage(),
      animeSearch: search,
    );
    addTearDown(store.dispose);
    final portal = FakePortal();
    await store.attach(portal);
    store.query = 'old';
    final old = store.search();
    store.query = 'new';
    final latest = store.search();
    search.pending['new']!.complete([catalog.items.last]);
    await latest;
    search.pending['old']!.complete([catalog.items.first]);
    await old;
    expect(store.searchResults.single.id, catalog.items.last.id);
    expect(store.searchedQuery, 'new');
    expect(store.operation.intent, BrowserIntent.catalog);
  });

  test(
    'public search uses the owned official network channel without navigating away',
    () async {
      final service = OfficialAnimeSearch(toTraditional: (text) => text);
      final store = await _createStore(animeSearch: service);
      addTearDown(store.dispose);
      final portal = FakePortal()
        ..publicResponse = {
          'data': {
            'history': ['ignored-private-search-history'],
            'animeList': [
              {
                'animeSn': 10,
                'videoSn': 20,
                'title': '測試動畫',
                'cover': 'https://p2.bahamut.com.tw/10.jpg',
                'totalEpisode': 12,
              },
            ],
          },
        };
      await store.attach(portal);
      store.query = '測試';
      await store.search();
      expect(portal.publicRequests.single.path, '/anime/v1/search.php');
      expect(portal.publicRequests.single.queryParameters['kw'], '測試');
      expect(portal.publicRequestAccounts, [true]);
      expect(store.searchResults.single.id, '10');
      expect(store.browserVisible, isFalse);
      expect(portal.visited, [OfficialSite.home]);
      expect(store.favorites, isEmpty);
      expect(store.history, isEmpty);
      await service.recentSeries();
      expect(portal.publicRequestAccounts, [true, false, false]);
    },
  );

  test(
    'public search parses official series and video IDs without account state',
    () {
      final record = {
        'animeSn': 10,
        'videoSn': 20,
        'title': '測試動畫',
        'cover': 'https://p2.bahamut.com.tw/10.jpg',
        'totalEpisode': 12,
        'dateInfo': '年份：2026/11',
        'favorite': true,
      };
      Json response(Json value) => {
        'data': {
          'animeList': [value],
        },
      };
      final item = OfficialAnimeSearch.parseResponse(response(record)).single;
      expect(item.id, '10');
      expect(item.latestVideoId, '20');
      expect(item.year, '2026/11');
      expect(item.sections, isEmpty);
      expect(
        OfficialAnimeSearch.parseResponse({
          'data': {'animeList': []},
        }),
        isEmpty,
      );
      expect(
        () => OfficialAnimeSearch.parseResponse(
          response({...record, 'cover': 'https://attacker.test/poster.jpg'}),
        ),
        throwsFormatException,
      );
      expect(
        () => OfficialAnimeSearch.parseResponse({
          'error': {'code': 0},
        }),
        throwsA(isA<Error>()),
      );
    },
  );

  test(
    'public main visuals enrich the cache without replacing episode thumbnails or account data',
    () async {
      final disk = MemoryStorage();
      final search = FakeSearch();
      final item = Anime.fromJson({
        'id': '10',
        'title': 'Public Anime',
        'cover': 'https://p2.bahamut.com.tw/episode.jpg',
        'sections': ['season'],
        'updateDate': '2026-11-06',
      });
      search.recent = [
        const Anime(
          id: '10',
          title: 'Public Anime',
          cover: 'https://p2.bahamut.com.tw/main.jpg',
          poster: 'https://p2.bahamut.com.tw/main.jpg',
        ),
      ];
      final store = await _createStore(storage: disk, animeSearch: search);
      addTearDown(store.dispose);
      store.catalog = Catalog(items: [item], fetchedAt: '2026-11-06T00:00:00Z');
      await store.attach(FakePortal());
      for (var i = 0; i < 20 && store.postersLoading; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(store.catalog.items.single.cover, item.cover);
      expect(store.catalog.items.single.poster, search.recent.single.poster);
      expect(store.favorites, isEmpty);
      expect(store.history, isEmpty);
      final cached = await CatalogCache(disk).load();
      expect(cached!.items.single.poster, search.recent.single.poster);
      await store.receive(
        jsonEncode({
          'type': 'catalog',
          'requestId': store.operation.id,
          'fetchedAt': '2026-11-06T00:10:00Z',
          'items': [item.toJson()],
        }),
        origin: OfficialSite.home,
        source: OfficialSite.home,
        isMainFrame: true,
      );
      expect(store.catalog.items.single.poster, search.recent.single.poster);
      expect(store.catalog.items.single.updateDate, '2026-11-06');
      expect(Catalog.validDate('2026-02-30'), isFalse);
      expect(Catalog.validDate('2026-02-28'), isTrue);
    },
  );

  test(
    'simplified and traditional interface dictionaries are complete',
    () async {
      final store = await _createStore(storage: MemoryStorage());
      addTearDown(store.dispose);
      expect(
        store.dictionaries['zh-Hans']!.keys.toSet(),
        store.dictionaries['zh-Hant']!.keys.toSet(),
      );
      expect(AppStore.languageForSystem('zh-CN'), 'zh-Hans');
      expect(AppStore.languageForSystem('zh-Hans-US'), 'zh-Hans');
      expect(AppStore.languageForSystem('zh-TW'), 'zh-Hant');
    },
  );
}
