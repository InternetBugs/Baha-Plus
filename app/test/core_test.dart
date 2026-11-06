import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:baha_plus/core/browser_request.dart';
import 'package:baha_plus/core/browser_presentation.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/device_storage.dart';

class MemoryStorage implements DeviceStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class FakePortal implements OfficialPortal {
  final visited = <Uri>[];
  final scripts = <String>[];
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
      final store = await AppStore.create(storage: MemoryStorage());
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
      final store = await AppStore.create(storage: MemoryStorage());
      addTearDown(store.dispose);
      expect(store.folding.matches('世界最強的魔女，就此開始', '世界最强的魔女'), isTrue);
      expect(
        store.folding.matches('Fate/strange Fake', 'Ｆａｔｅ　ｓｔｒａｎｇｅ'),
        isTrue,
      );
      expect(store.folding.normalize('𠮷-野'), '𠮷野');
      expect(store.folding.normalize('e\u0301'), store.folding.normalize('é'));
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
      final store = await AppStore.create(storage: disk);
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
      final restarted = await AppStore.create(storage: disk);
      addTearDown(restarted.dispose);
      expect(restarted.catalog.encode(), catalog.encode());
      expect(restarted.catalogSource, 'cache');
      expect(restarted.favorites, isEmpty);
      expect(restarted.history, isEmpty);
      expect(disk.values.keys, [CatalogCache.key]);
    },
  );

  test('new search discards stale asynchronous response', () async {
    final store = await AppStore.create(storage: MemoryStorage());
    addTearDown(store.dispose);
    final portal = FakePortal();
    await store.attach(portal);
    store.query = 'old';
    await store.search();
    final old = store.operation;
    store.query = 'new';
    await store.search();
    await store.receive(
      jsonEncode({
        'type': 'search',
        'requestId': old.id,
        'items': fixture['items'],
        'fetchedAt': fixture['fetchedAt'],
      }),
      origin: OfficialSite.home,
      source: OfficialSite.search('old'),
      isMainFrame: true,
    );
    expect(store.searchResults, isEmpty);
    expect(store.operation.query, 'new');
  });

  test(
    'simplified and traditional interface dictionaries are complete',
    () async {
      final store = await AppStore.create(storage: MemoryStorage());
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
