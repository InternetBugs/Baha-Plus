import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/core/search_folding.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/device_storage.dart';
import 'package:baha_plus/data/native_account_api.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/data/official_app_api.dart';
import 'package:baha_plus/data/official_search.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/catalog_pages.dart';
import 'package:baha_plus/ui/comments_page.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:baha_plus/ui/native_video_surface.dart';
import 'package:baha_plus/ui/player_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

class _MemoryStorage implements DeviceStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> clearAccountData() async {}
}

class _FakeMetadataApi extends OfficialAppApi {
  _FakeMetadataApi({this.libraryPages = const []});
  final List<({List<Anime> items, bool hasMore})> libraryPages;
  int libraryPageCalls = 0;

  @override
  Future<Catalog> fetchCatalog() async => const Catalog();

  @override
  Future<({List<Anime> items, bool hasMore})> fetchLibraryPage(
    int page, {
    Future<void>? cancel,
  }) async {
    libraryPageCalls++;
    if (page - 1 < libraryPages.length) return libraryPages[page - 1];
    return (items: const <Anime>[], hasMore: false);
  }
}

class _FakeSearch implements AnimeSearch {
  bool shouldFail = false;
  int calls = 0;

  @override
  Future<List<Anime>> search(String query, {bool useAccount = false}) async {
    calls++;
    if (shouldFail) throw StateError('offline');
    return const [
      Anime(
        id: '900',
        title: '搜尋結果作品',
        cover: 'https://p2.bahamut.com.tw/900.jpg',
        latestVideoId: '9001',
      ),
    ];
  }

  @override
  Future<List<Anime>> recentSeries() async => const [];

  @override
  void dispose() {}
}

class _FakeAccountApi extends NativeAccountApi {
  final loadedVideos = <String>[];

  @override
  Future<Json> community(
    String action,
    Json arguments, {
    void Function()? checkCurrent,
  }) async {
    if (action == 'comments') {
      final videoId = arguments['videoId'] as String;
      loadedVideos.add(videoId);
      return {
        'ok': true,
        'messageId': 'msg-$videoId',
        'total': 1,
        'nextPage': 0,
        'comments': [
          {
            'id': 'c-$videoId',
            'author': '評論者',
            'text': '第 $videoId 集留言',
            'time': '剛剛',
            'likes': 3,
            'dislikes': 0,
            'vote': 0,
            'replies': 0,
          },
        ],
      };
    }
    return {'ok': true};
  }
}

class _SurfacePlayback extends NativePlayback {
  _SurfacePlayback({double position = 1})
    : super(
        document: 'opt-test',
        source: NativePlaybackSource.fromJson({
          'master': 'https://bahamut.akamaized.net/master.m3u8',
          'variants': [],
          'position': 0,
          'duration': 1200,
          'rate': 1,
          'paused': true,
          'muted': false,
        }),
        userAgent: '',
        onState: (_) {},
      ) {
    _state = PlaybackState(
      phase: PlaybackPhase.content,
      surfaceReady: true,
      position: position,
      duration: 1200,
      paused: false,
    );
  }

  late PlaybackState _state;

  @override
  PlaybackState get state => _state;
}

AppStore _buildStore({
  _FakeMetadataApi? metadataApi,
  _FakeSearch? search,
  _FakeAccountApi? accountApi,
  Catalog? catalog,
}) => AppStore(
  storage: _MemoryStorage(),
  dictionaries: const {
    'zh-Hant': {
      'explore': '探索',
      'schedule': '排期',
      'library': '片庫',
      'watchHistory': '觀看紀錄',
      'search': '搜尋',
      'all': '全部',
      'seasonFilter': '本季',
      'hotFilter': '熱門',
      'favorites': '追番',
      'noFavorites': '還沒有追番作品',
      'noFavoritesHint': '在詳情頁收藏喜歡的作品',
      'discover': '去探索',
      'searchUnavailable': '無法搜尋',
      'noResults': '沒有找到符合的作品',
      'retry': '重試',
      'loadMoreCatalog': '載入更多片庫',
      'libraryScopeHint': '目前顯示首頁目錄',
      'libraryCatalogEnd': '已顯示全部片庫作品',
      'episodes': '選集',
      'watch': '觀看',
      'save': '追番',
      'unsave': '已追番',
      'openComments': '留言板',
      'comments': '留言板',
      'selectBoardEpisode': '切換集數留言',
      'episodeNumber': '第 {n} 集',
      'currentEpisode': '本集',
      'detail': '詳情',
      'close': '關閉',
      'sortRecommended': '推薦',
      'sortLatest': '最新',
      'noComments': '暫無留言',
      'commentLoginRequired': '登入後可留言',
      'commentPlaceholder': '寫下留言',
      'loading': '載入中',
    },
    'zh-Hans': {},
  },
  folding: SearchFolding(const {}),
  scripts: const {},
  metadataApi: metadataApi ?? _FakeMetadataApi(),
  animeSearch: search ?? _FakeSearch(),
  accountApi: accountApi ?? _FakeAccountApi(),
  catalog:
      catalog ??
      const Catalog(
        items: [
          Anime(
            id: '1',
            title: '測試動畫一',
            cover: 'https://p2.bahamut.com.tw/1.jpg',
            latestVideoId: '101',
            sections: ['season'],
          ),
        ],
      ),
);

void main() {
  test('formatPlaybackTime formats <1h as MM:SS and >=1h as H:MM:SS', () {
    expect(formatPlaybackTime(0), '00:00');
    expect(formatPlaybackTime(125), '02:05');
    expect(formatPlaybackTime(3599), '59:59');
    expect(formatPlaybackTime(3600), '1:00:00');
    expect(formatPlaybackTime(3665), '1:01:05');
  });

  testWidgets(
    'NativeVideoSurface preserves cached TextPainters and sprites across opacity changes',
    (tester) async {
      final playback = _SurfacePlayback(position: 1);
      final items = [
        NativeDanmaku.fromJson({
          'id': '1',
          'text': '透明度滑塊測試彈幕',
          'time': 0.5,
          'mode': 'rolling',
          'size': 18,
          'color': '#FFFFFF',
        }),
      ];

      Widget buildSurface(double opacity) => MaterialApp(
        home: NativeVideoSurface(
          playback: playback,
          danmaku: items,
          settings: DanmakuSettings(opacity: opacity),
          errorLabel: 'error',
          retryLabel: 'retry',
          onRetry: () {},
        ),
      );

      await tester.pumpWidget(buildSurface(0.8));
      final state = tester.state<NativeVideoSurfaceState>(
        find.byType(NativeVideoSurface),
      );
      expect(state.cachedTextPainters, 1);
      final initialSprites = state.cachedRasterImages;

      // Changing opacity alone must not clear laid-out text or raster sprites.
      await tester.pumpWidget(buildSurface(0.35));
      expect(state.cachedTextPainters, 1);
      expect(state.cachedRasterImages, initialSprites);

      await tester.pumpWidget(const SizedBox());
      playback.dispose();
    },
  );

  testWidgets('SearchStatus renders retry button and retries failed search', (
    tester,
  ) async {
    final search = _FakeSearch()..shouldFail = true;
    final store = _buildStore(search: search);
    store.tab = 4;
    store.query = '測試';
    await store.search();
    expect(store.searchFailed, isTrue);

    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        child: MaterialApp(
          home: Scaffold(body: SearchStatus(store: store)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('search-retry-button')), findsOneWidget);

    search.shouldFail = false;
    final beforeCalls = search.calls;
    await tester.tap(find.byKey(const ValueKey('search-retry-button')));
    await tester.pumpAndSettle();
    expect(search.calls, greaterThan(beforeCalls));
    expect(store.searchFailed, isFalse);
    store.dispose();
  });

  testWidgets(
    'LibraryContent shows empty favorites guidance and loads additional catalog pages',
    (tester) async {
      final api = _FakeMetadataApi(
        libraryPages: [
          (
            items: const [
              Anime(
                id: '2',
                title: '第二頁動畫',
                cover: 'https://p2.bahamut.com.tw/2.jpg',
                latestVideoId: '102',
              ),
            ],
            hasMore: false,
          ),
        ],
      );
      final store = _buildStore(metadataApi: api)..accountSynced = true;

      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          child: MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: Listenable.merge([
                  store,
                  store.libraryFilterNotifier,
                ]),
                builder: (context, _) => CustomScrollView(
                  slivers: [
                    LibraryContent(
                      store: store,
                      openDetail: (_) {},
                      connectAccount: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('library-load-more')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('library-load-more')));
      await tester.pumpAndSettle();
      expect(api.libraryPageCalls, 1);
      expect(find.text('第二頁動畫'), findsOneWidget);
      expect(find.text(store.t('libraryCatalogEnd')), findsOneWidget);

      store.libraryFilter = 'favorites';
      await tester.pump();
      expect(
        find.byKey(const ValueKey('library-empty-favorites-discover')),
        findsOneWidget,
      );
      expect(find.text(store.t('noFavorites')), findsOneWidget);
      store.dispose();
    },
  );

  testWidgets(
    'DetailPage shows comments entry and CommentsPage switches episode via picker',
    (tester) async {
      final accountApi = _FakeAccountApi();
      final store = _buildStore(accountApi: accountApi);
      const anime = Anime(
        id: '1',
        title: '測試動畫一',
        cover: 'https://p2.bahamut.com.tw/1.jpg',
        latestVideoId: '102',
      );
      store.selectedAnime = anime;
      store.detail = AnimeDetail.fromJson({
        'title': anime.title,
        'description': '故事簡介',
        'poster': null,
        'rating': null,
        'episodes': [
          {'id': '101', 'label': '1'},
          {'id': '102', 'label': '2'},
        ],
        'metadata': <Json>[],
      });
      store.history = [
        WatchEntry.fromJson({
          'anime': anime.toJson(),
          'videoId': '101',
          'episodeLabel': '1',
        }),
      ];

      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          child: MaterialApp(
            home: DetailPage(store: store, anime: anime),
          ),
        ),
      );
      await tester.pump();
      final openComments = find.byKey(const ValueKey('detail-open-comments'));
      await tester.scrollUntilVisible(
        openComments,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(openComments, findsOneWidget);

      await tester.tap(openComments);
      await tester.pumpAndSettle();
      expect(find.byType(CommentsPage), findsOneWidget);
      expect(accountApi.loadedVideos, contains('101'));
      expect(
        find.byKey(const ValueKey('board-episode-picker')),
        findsOneWidget,
      );
      store.dispose();
    },
  );

  testWidgets(
    'BahaPlusApp enforces GlassQuality.minimal adaptive ceiling in performance mode',
    (tester) async {
      final store = _buildStore();
      await store.setGlassStyle('performance');

      GlassQuality? observedQuality;
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          child: BahaPlusApp(store: store, mountPortal: false),
        ),
      );
      await tester.pump();
      final context = tester.element(find.byType(GlassScaffold).first);
      observedQuality = GlassAdaptiveScopeData.maybeOf(
        context,
      )?.effectiveQuality;
      expect(observedQuality, GlassQuality.minimal);
      store.dispose();
    },
  );
}
