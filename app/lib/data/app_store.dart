import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/browser_request.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../core/playback_state.dart';
import '../core/search_folding.dart';
import 'device_storage.dart';
import 'official_search.dart';

abstract interface class OfficialPortal {
  Future<void> load(Uri uri);
  Future<void> reload();
  Future<void> goBack();
  Future<dynamic> evaluate(String script);
  Future<Json> fetchPublicCatalog(Uri uri, {required bool useAccount});
  Future<Json> community(String action, Json arguments);
}

class AppStore extends ChangeNotifier {
  AppStore({
    required this.storage,
    required this.dictionaries,
    required this.folding,
    required this.scripts,
    AnimeSearch? animeSearch,
    this.language = 'zh-Hant',
    this.appearance = 'system',
    this.catalog = const Catalog(),
  }) : searchService =
           animeSearch ??
           OfficialAnimeSearch(toTraditional: folding.toTraditional),
       cache = CatalogCache(storage),
       catalogSource = catalog.items.isEmpty ? 'empty' : 'cache';

  static Future<AppStore> create({
    DeviceStorage? storage,
    AnimeSearch? animeSearch,
  }) async {
    final disk = storage ?? PreferencesStorage();
    final dictionaries = <String, Map<String, String>>{};
    for (final locale in ['zh-Hans', 'zh-Hant']) {
      dictionaries[locale] =
          (jsonDecode(await rootBundle.loadString('assets/i18n/$locale.json'))
                  as Map<String, dynamic>)
              .cast<String, String>();
    }
    final folding =
        (jsonDecode(
                  await rootBundle.loadString(
                    'assets/data/search-folding.json',
                  ),
                )
                as Map<String, dynamic>)
            .cast<String, String>();
    final traditional =
        (jsonDecode(
                  await rootBundle.loadString(
                    'assets/data/search-traditional.json',
                  ),
                )
                as Map<String, dynamic>)
            .cast<String, String>();
    final scripts = <String, String>{};
    for (final name in [
      'catalog',
      'detail',
      'account-sync',
      'favorite-action',
      'player',
      'community',
    ]) {
      scripts[name] = await rootBundle.loadString('assets/adapters/$name.js');
    }
    String? language, appearance, danmaku;
    try {
      language = await disk.read('baha.device.language');
      appearance = await disk.read('baha.device.appearance');
      danmaku = await disk.read('baha.device.danmaku');
    } catch (_) {
      // Missing device preferences must not prevent startup.
    }
    final store = AppStore(
      storage: disk,
      dictionaries: dictionaries,
      folding: SearchFolding(folding, traditionalMapping: traditional),
      animeSearch: animeSearch,
      scripts: scripts,
      language: const ['zh-Hans', 'zh-Hant'].contains(language)
          ? language!
          : languageForSystem(
              PlatformDispatcher.instance.locale.toLanguageTag(),
            ),
      appearance: const ['system', 'light', 'dark'].contains(appearance)
          ? appearance!
          : 'system',
      catalog: await CatalogCache(disk).load() ?? const Catalog(),
    );
    try {
      if (danmaku != null) {
        store.danmakuSettings = DanmakuSettings.fromJson(
          jsonDecode(danmaku) as Json,
        );
      }
    } catch (_) {
      // A damaged device preference falls back to readable defaults.
    }
    return store;
  }

  static String languageForSystem(String tag) {
    final value = tag.toLowerCase().replaceAll('_', '-');
    return value.contains('hans') ||
            value.contains('-cn') ||
            value.contains('-sg') ||
            value.contains('-my')
        ? 'zh-Hans'
        : 'zh-Hant';
  }

  final DeviceStorage storage;
  final AnimeSearch searchService;
  final CatalogCache cache;
  final Map<String, Map<String, String>> dictionaries;
  final SearchFolding folding;
  final Map<String, String> scripts;
  String language, appearance;
  Catalog catalog;
  String catalogSource;
  List<Anime> favorites = [], searchResults = [];
  List<WatchEntry> history = [];
  AccountProfile? accountProfile;
  bool accountSynced = false, accountNeedsRefresh = false;
  bool searching = false, searchFailed = false;
  int tab = 0;
  String libraryFilter = 'all', _query = '', searchedQuery = '';
  Anime? selectedAnime;
  AnimeDetail? detail;
  Anime? playingAnime;
  AnimeDetail? playerDetail;
  String? playingVideoId;
  bool playerFullscreen = false;
  final playback = ValueNotifier<PlaybackState>(const PlaybackState());
  bool detailLoading = false, detailFailed = false;
  bool browserVisible = false, browserError = false, busy = false;
  bool verificationRequired = false, browserCanGoBack = false;
  String browserTitle = '';
  String? notice;
  Uri? browserUri;
  BrowserRequest operation = BrowserRequest(intent: BrowserIntent.catalog);
  OfficialPortal? _portal;
  Uri? _pendingUri;
  Anime? _pendingAnime;
  bool _desiredFavorite = false, _disposed = false;
  bool _applicationActive = true;
  Timer? _deadline;
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  bool postersLoading = false;
  final _posterIndex = <String, String>{};
  String? _accountSyncDocument;
  DanmakuSettings danmakuSettings = const DanmakuSettings();
  List<AnimeNotification> notifications = [];
  final Set<String> _readNotifications = {};
  bool notificationsLoading = false;
  String? notificationsError;
  int _notificationGeneration = 0;
  final Set<String> _communityWrites = {};

  int get unreadNotifications =>
      notifications.where((item) => !notificationRead(item)).length;
  bool notificationRead(AnimeNotification item) =>
      _readNotifications.contains(item.id);

  Future<Json> community(String action, Json arguments) async {
    final portal = _portal;
    if (portal == null || !_applicationActive || _disposed) {
      throw const CommunityException('unavailable');
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await portal.community(action, {
          ...arguments,
          if (accountProfile != null) 'owner': accountProfile!.id,
        });
        if (result['ok'] != true) {
          throw CommunityException(result['code'] as String? ?? 'network');
        }
        return result;
      } on CommunityException catch (error) {
        // Background account sync can replace its ticket without replacing the
        // official document. Retry only reads; a write must never be repeated.
        if (attempt != 0 ||
            error.code != 'stale' ||
            !communityReadActions.contains(action) ||
            _disposed ||
            !_applicationActive) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (_disposed || !_applicationActive) {
          throw const CommunityException('unavailable');
        }
      }
    }
    throw const CommunityException('stale');
  }

  Future<CommentPage> loadComments(
    String videoId, {
    int order = 1,
    int page = 0,
  }) async => CommentPage.fromJson(
    await community('comments', {
      'videoId': videoId,
      'order': order,
      'page': page,
    }),
  );

  Future<List<OfficialComment>> loadReplies(String commentId) async =>
      CommentPage.parseComments(
        (await community('replies', {'commentId': commentId}))['comments'],
      );

  Future<void> _writeCommunity(
    String key,
    String action,
    Json arguments,
  ) async {
    if (!_communityWrites.add(key)) throw const CommunityException('busy');
    try {
      await community(action, arguments);
    } finally {
      _communityWrites.remove(key);
    }
  }

  Future<void> sendComment({
    required String videoId,
    required String messageId,
    required String text,
    String? commentId,
  }) async {
    if (text.trim().isEmpty || text.runes.length > 2000) {
      throw const CommunityException('input');
    }
    await _writeCommunity('comment:$messageId', 'comment-send', {
      'videoId': videoId,
      'messageId': messageId,
      'text': text.trim(),
      'commentId': ?commentId,
    });
  }

  Future<void> voteComment(OfficialComment comment, int type) =>
      _writeCommunity('vote:${comment.id}', 'comment-vote', {
        'commentId': comment.id,
        'type': type,
        'remove': comment.vote == (type == 1 ? 1 : -1),
      });

  Future<void> sendDanmaku(
    String text, {
    String color = '#FFFFFF',
    int position = 0,
    int size = 1,
  }) async {
    if (!showsPlayer ||
        !playback.value.canControl ||
        playingVideoId == null ||
        !DanmakuSettings.validMessage(text)) {
      throw const CommunityException('input');
    }
    await _writeCommunity('danmaku', 'danmaku-send', {
      'videoId': playingVideoId,
      'text': text.trim(),
      'color': color,
      'position': position,
      'size': size,
    });
  }

  Future<void> setDanmakuSettings(DanmakuSettings value) async {
    danmakuSettings = value;
    _emit();
    if (showsPlayer) {
      try {
        await _portal?.evaluate(
          'window.__bahaPlayerBridge?.configure(${jsonEncode(operation.id)},'
          '${jsonEncode(value.toJson())}); true;',
        );
      } catch (_) {
        // The next document commit receives the saved preferences.
      }
    }
    await _savePreference('baha.device.danmaku', jsonEncode(value.toJson()));
  }

  Future<void> refreshNotifications() async {
    if (notificationsLoading) return;
    final generation = ++_notificationGeneration;
    final owner = accountProfile?.id.toLowerCase();
    notificationsLoading = true;
    notificationsError = null;
    _emit();
    try {
      final result = await community('notifications', {});
      if (_disposed || generation != _notificationGeneration) return;
      final actualOwner = result['owner'] as String;
      if (actualOwner.isEmpty || (owner != null && actualOwner != owner)) {
        throw const CommunityException('login');
      }
      final raw = result['items'] as List;
      if (raw.length > 200) {
        throw const FormatException('Too many notifications');
      }
      final items = raw
          .map((item) => AnimeNotification.fromJson(item as Json))
          .toList();
      if (items.map((item) => item.id).toSet().length != items.length) {
        throw const FormatException('Duplicate notifications');
      }
      final stored = await storage.read('baha.notifications.read.$actualOwner');
      if (_disposed || generation != _notificationGeneration) return;
      final currentRead = actualOwner == _notificationOwner
          ? _readNotifications.toSet()
          : <String>{};
      _readNotifications.clear();
      if (stored != null) {
        try {
          _readNotifications.addAll(
            (jsonDecode(stored) as List).cast<String>().take(500),
          );
        } catch (_) {}
      }
      _readNotifications.addAll(currentRead);
      notifications = items;
      _notificationOwner = actualOwner;
    } catch (error) {
      if (_disposed || generation != _notificationGeneration) return;
      notificationsError = error is CommunityException ? error.code : 'network';
      if (notificationsError == 'login') {
        notifications = [];
        _readNotifications.clear();
      }
    } finally {
      if (!_disposed && generation == _notificationGeneration) {
        notificationsLoading = false;
        _emit();
      }
    }
  }

  String? _notificationOwner;
  Future<void> markNotificationsRead([AnimeNotification? item]) async {
    final owner = _notificationOwner;
    if (owner == null) return;
    _readNotifications.addAll(
      item == null ? notifications.map((e) => e.id) : [item.id],
    );
    _emit();
    await _savePreference(
      'baha.notifications.read.$owner',
      jsonEncode(_readNotifications.toList().reversed.take(500).toList()),
    );
  }

  Future<void> openNotification(AnimeNotification item) async {
    await markNotificationsRead(item);
    // Resolve the real series ID; a video ID must never be used as a series ID.
    try {
      final detail = await community('notification-target', {
        'videoId': item.videoId,
      });
      final anime = Anime.fromJson(detail['anime'] as Json);
      await play(
        anime,
        episode: Episode(id: item.videoId, label: ''),
      );
    } catch (_) {
      browserTitle = item.title;
      await _load(
        OfficialSite.video(item.videoId),
        BrowserIntent.browse,
        visible: true,
      );
    }
  }

  void _resetNotifications() {
    _notificationGeneration++;
    notifications = [];
    _readNotifications.clear();
    _notificationOwner = null;
    notificationsLoading = false;
    notificationsError = null;
  }

  String t(String key) => dictionaries[language]?[key] ?? key;
  bool get simplified => language == 'zh-Hans';
  bool get canRetryFavorite => operation.intent == BrowserIntent.favorite;
  bool get browserIsPlayer =>
      operation.intent == BrowserIntent.play ||
      (browserUri != null && OfficialSite.desktopPlayer(browserUri!));
  bool get showsPlayer =>
      operation.intent == BrowserIntent.play && playingAnime != null;
  String get playingEpisodeLabel {
    for (final episode in playerDetail?.episodes ?? <Episode>[]) {
      if (episode.id == playingVideoId) return episode.label;
    }
    return playingAnime?.episodeLabel ?? '';
  }

  void setPlayerFullscreen(bool value) {
    if (playerFullscreen == value) return;
    playerFullscreen = value;
    _emit();
  }

  Future<void> dismissBrowser() async {
    if (showsPlayer && playerFullscreen) {
      setPlayerFullscreen(false);
    } else {
      await closeBrowser();
    }
  }

  Future<void> setApplicationActive(bool active) async {
    if (_applicationActive == active) return;
    _applicationActive = active;
    if (active && !browserVisible && !busy && _portal != null) {
      await syncAccount();
    }
    if (!browserVisible || !showsPlayer) return;
    final document = operation.id;
    try {
      await _portal?.evaluate('''
if (window.__bahaDocumentNonce === ${jsonEncode(document)}) {
  ${active ? 'window.__bahaMediaSuspended = false;' : _suspendMedia}
} true;
''');
    } catch (_) {
      // A navigation can replace the document while the application is hidden.
      // Its next commit receives the current lifecycle state below.
    }
  }

  Future<void> controlPlayer(String action, [double? value]) async {
    if (!_applicationActive ||
        !browserVisible ||
        !showsPlayer ||
        !playback.value.canOperate ||
        !const [
          'play',
          'pause',
          'seek',
          'rate',
          'mute',
          'quality',
          'danmaku',
        ].contains(action)) {
      return;
    }
    if (!playback.value.canControl &&
        !const ['play', 'pause', 'mute'].contains(action)) {
      return;
    }
    if (value != null && !value.isFinite) return;
    await _portal?.evaluate(
      'window.__bahaPlayerBridge?.command(${jsonEncode(operation.id)},'
      '${jsonEncode(action)},${jsonEncode(value)}); true;',
    );
  }

  List<Anime> get seasonal =>
      catalog.items.where((item) => item.sections.contains('season')).toList();
  List<Anime> get popular =>
      catalog.items.where((item) => item.sections.contains('hot')).toList();
  bool get _usesOfficialSearch =>
      tab == 4 || (tab == 2 && libraryFilter == 'all');
  String get query => _query;
  set query(String value) {
    if (value == _query) return;
    _query = value;
    searchedQuery = '';
    searchResults = [];
    _searchDebounce?.cancel();
    _searchGeneration++;
    searching = value.trim().isNotEmpty && _usesOfficialSearch;
    searchFailed = false;
    _emit();
    if (searching) {
      _searchDebounce = Timer(
        const Duration(milliseconds: 350),
        () => unawaited(search()),
      );
    }
  }

  bool isFavorite(Anime item) => favorites.any((e) => e.id == item.id);
  List<Anime> get searchMatches {
    if (query.trim().isEmpty) return catalog.items;
    return searchedQuery == query ? searchResults : [];
  }

  List<Anime> get libraryItems {
    if (libraryFilter == 'all' && query.trim().isNotEmpty) return searchMatches;
    final source = libraryFilter == 'favorites' ? favorites : catalog.items;
    return source
        .where(
          (item) =>
              (const ['all', 'favorites'].contains(libraryFilter) ||
                  item.sections.contains(libraryFilter)) &&
              folding.matches(item.title, query),
        )
        .toList();
  }

  void selectTab(int value, {String? filter}) {
    tab = value;
    if (filter != null) {
      libraryFilter = filter;
      query = '';
    }
    _emit();
    if (value == 3 && !browserVisible && !busy && _portal != null) {
      unawaited(syncAccount());
    }
    if (_usesOfficialSearch &&
        query.trim().isNotEmpty &&
        searchedQuery != query &&
        !searching) {
      unawaited(search());
    }
  }

  Future<void> setLanguage(String value) async {
    if (!const ['zh-Hans', 'zh-Hant'].contains(value)) return;
    language = value;
    _emit();
    await _savePreference('baha.device.language', value);
  }

  Future<void> setAppearance(String value) async {
    if (!const ['system', 'light', 'dark'].contains(value)) return;
    appearance = value;
    _emit();
    await _savePreference('baha.device.appearance', value);
  }

  Future<void> _savePreference(String key, String value) async {
    try {
      await storage.write(key, value);
    } catch (_) {
      notice = t('storageError');
      _emit();
    }
  }

  Future<void> attach(OfficialPortal portal) async {
    _portal = portal;
    if (searchService case final OfficialAnimeSearch search) {
      search.useTransport(portal.fetchPublicCatalog);
    }
    if (_pendingUri != null) {
      final uri = _pendingUri!;
      _pendingUri = null;
      await portal.load(uri);
    } else {
      await refreshCatalog();
    }
    unawaited(_refreshPosters());
  }

  void _rememberPosters(Iterable<Anime> series) {
    for (final item in series) {
      if (item.poster != null) _posterIndex[item.id] = item.poster!;
    }
    final merged = _mergePosters(catalog);
    if (!identical(merged, catalog)) {
      catalog = merged;
      _emit();
    }
  }

  Catalog _mergePosters(Catalog source) {
    var changed = false;
    final items = [
      for (final item in source.items)
        if (item.poster == null && _posterIndex.containsKey(item.id))
          () {
            changed = true;
            return Anime.fromJson({
              ...item.toJson(),
              'poster': _posterIndex[item.id],
            });
          }()
        else
          item,
    ];
    return changed
        ? Catalog(items: items, fetchedAt: source.fetchedAt)
        : source;
  }

  Future<void> _refreshPosters() async {
    if (_disposed ||
        postersLoading ||
        catalog.items.every((e) => e.poster != null)) {
      return;
    }
    postersLoading = true;
    try {
      final recent = await searchService.recentSeries();
      if (_disposed) return;
      _rememberPosters(recent);
      await cache.save(catalog);
      final pending = catalog.items.where((e) => e.poster == null).toList();
      var next = 0;
      final found = <Anime>[];
      Future<void> worker() async {
        while (!_disposed && next < pending.length) {
          final item = pending[next++];
          try {
            final matches = await searchService.search(
              item.title,
              useAccount: false,
            );
            found.addAll(matches.where((match) => match.id == item.id));
          } catch (_) {
            // Keep existing public artwork on a temporary metadata failure.
          }
        }
      }

      await Future.wait([for (var i = 0; i < 3; i++) worker()]);
      if (_disposed) return;
      _rememberPosters(found);
      await cache.save(catalog);
    } catch (_) {
      // An unavailable artwork endpoint must not discard the catalog cache.
    } finally {
      postersLoading = false;
    }
  }

  void updateNavigation(Uri? uri, {required bool canGoBack}) {
    browserUri = uri;
    browserCanGoBack = canGoBack;
    final nextVideo = uri?.queryParameters['sn'];
    if (showsPlayer &&
        uri != null &&
        OfficialSite.trustedOrigin(uri) &&
        uri.path == '/animeVideo.php' &&
        nextVideo != playingVideoId &&
        (playerDetail?.episodes.any((e) => e.id == nextVideo) ?? false)) {
      playingVideoId = nextVideo;
      playback.value = const PlaybackState();
      _begin(BrowserIntent.play);
    }
    _emit();
  }

  Future<void> refreshCatalog() async {
    if (browserVisible) return;
    await _load(OfficialSite.home, BrowserIntent.catalog, visible: false);
  }

  Future<void> openOfficial() async {
    browserTitle = t(
      verificationRequired ? 'officialVerification' : 'openOfficial',
    );
    await _load(OfficialSite.home, BrowserIntent.catalog, visible: true);
  }

  Future<void> openDetail(Anime anime) async {
    selectedAnime = anime;
    detail = null;
    detailLoading = true;
    detailFailed = false;
    _pendingAnime = anime;
    _emit();
    if (browserUri != null && OfficialSite.trustedOrigin(browserUri!)) {
      _begin(BrowserIntent.detail);
      _armDeadline();
      await _runScript('detail', {'%ANIME_ID%': anime.id});
    } else {
      await _load(OfficialSite.home, BrowserIntent.detail, visible: false);
    }
  }

  Future<void> search() async {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) return;
    final input = query;
    final generation = ++_searchGeneration;
    searching = true;
    searchFailed = false;
    _emit();
    try {
      final items = await searchService.search(input);
      if (_disposed || generation != _searchGeneration || query != input) {
        return;
      }
      searchResults = items;
      searchedQuery = input;
      _rememberPosters(items);
    } catch (_) {
      if (_disposed || generation != _searchGeneration || query != input) {
        return;
      }
      searchResults = [];
      searchFailed = true;
    }
    if (generation == _searchGeneration) {
      searching = false;
      _emit();
    }
  }

  Future<void> connectAccount() async {
    _resetNotifications();
    accountProfile = null;
    favorites = [];
    history = [];
    accountSynced = false;
    browserTitle = t('officialAccount');
    await _load(
      OfficialSite.home.resolve('mygather.php'),
      BrowserIntent.account,
      visible: true,
    );
  }

  Future<void> toggleFavorite(Anime anime) async {
    _pendingAnime = anime;
    _desiredFavorite = !isFavorite(anime);
    browserTitle = t('favorites');
    await _load(
      OfficialSite.search(anime.title),
      BrowserIntent.favorite,
      visible: true,
    );
  }

  Future<void> play(Anime anime, {Episode? episode}) async {
    if (playingAnime?.id != anime.id) {
      playerDetail = selectedAnime?.id == anime.id ? detail : null;
    }
    playingAnime = anime;
    _pendingAnime = anime;
    browserTitle = anime.title;
    accountNeedsRefresh = true;
    final videoId = episode?.id ?? anime.latestVideoId;
    playingVideoId = videoId;
    playback.value = const PlaybackState();
    await _load(
      videoId == null
          ? OfficialSite.series(anime.id)
          : OfficialSite.video(videoId),
      BrowserIntent.play,
      visible: true,
    );
  }

  Future<void> continueWatching(WatchEntry entry) async {
    await play(
      entry.anime,
      episode: Episode(id: entry.videoId, label: entry.episodeLabel),
    );
  }

  Future<void> closeBrowser() async {
    final document = operation.id;
    final refreshAccount =
        accountNeedsRefresh ||
        operation.intent == BrowserIntent.account ||
        operation.intent == BrowserIntent.accountRefresh;
    browserVisible = false;
    playerFullscreen = false;
    busy = false;
    _begin(BrowserIntent.idle);
    final closing = operation.id;
    _emit();
    try {
      await _portal?.evaluate('''
if (window.__bahaDocumentNonce === ${jsonEncode(document)}) {
  $_suspendMedia
} true;
''');
    } catch (_) {
      // A cancelled document may already have been destroyed by WebKit.
    }
    if (refreshAccount) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (operation.id == closing && !browserVisible) await syncAccount();
    } else if (operation.id == closing &&
        !browserVisible &&
        (verificationRequired || catalog.items.isEmpty)) {
      await refreshCatalog();
    }
  }

  Future<void> reloadBrowser() async {
    if (showsPlayer) playback.value = const PlaybackState();
    _begin(operation.intent);
    browserError = false;
    notice = null;
    busy = true;
    _emit();
    await _portal?.reload();
  }

  Future<void> goBack() async => _portal?.goBack();

  Future<void> syncAccount() async {
    if (showsPlayer ||
        (busy &&
            operation.intent == BrowserIntent.accountRefresh &&
            _accountSyncDocument == operation.id)) {
      return;
    }
    if (browserUri == null || !OfficialSite.trustedOrigin(browserUri!)) {
      browserTitle = t('officialAccount');
      await _load(
        OfficialSite.home.resolve('mygather.php'),
        browserVisible ? BrowserIntent.account : BrowserIntent.accountRefresh,
        visible: browserVisible,
      );
      return;
    }
    _begin(BrowserIntent.accountRefresh);
    _accountSyncDocument = operation.id;
    notice = null;
    busy = true;
    _armDeadline();
    _emit();
    await _runScript('account-sync');
  }

  Future<void> retryFavorite() async {
    if (!canRetryFavorite || _pendingAnime == null) return;
    await _runScript('favorite-action', {
      '%ANIME_ID%': _pendingAnime!.id,
      '__BAHA_DESIRED__': _desiredFavorite ? 'true' : 'false',
    });
  }

  Future<void> preparePlayerSurface(Uri? uri) async {
    if (!showsPlayer ||
        uri == null ||
        !OfficialSite.trustedOrigin(uri) ||
        uri.path != '/animeVideo.php' ||
        (playingVideoId != null &&
            uri.queryParameters['sn'] != playingVideoId)) {
      return;
    }
    await _portal?.evaluate('''
window.__bahaDocumentNonce = ${jsonEncode(operation.id)};
window.__bahaMediaSuspended = ${!_applicationActive};
window.__bahaDanmakuPreferences = ${jsonEncode(danmakuSettings.toJson())};
${_applicationActive ? '' : _suspendMedia} true;
''');
    await _runScript('player', {'%ANIME_ID%': playingAnime!.id});
  }

  Future<void> navigationFinished(Uri? uri) async {
    browserUri = uri;
    if (uri == null || !OfficialSite.trustedOrigin(uri)) {
      busy = false;
      _emit();
      return;
    }
    switch (operation.intent) {
      case BrowserIntent.catalog:
        await _runScript('catalog', {'%KIND%': 'catalog'});
      case BrowserIntent.search:
        await _runScript('catalog', {'%KIND%': 'search'});
      case BrowserIntent.detail:
        if (_pendingAnime != null) {
          await _runScript('detail', {'%ANIME_ID%': _pendingAnime!.id});
        }
      case BrowserIntent.account:
      case BrowserIntent.accountRefresh:
        await syncAccount();
      case BrowserIntent.favorite:
        await retryFavorite();
        busy = false;
      case BrowserIntent.idle:
        if (!browserVisible) await _portal?.evaluate('$_suspendMedia true;');
        busy = false;
      case BrowserIntent.play:
        await preparePlayerSurface(uri);
        busy = false;
      case BrowserIntent.browse:
        await _portal?.evaluate('''
window.__bahaDocumentNonce = ${jsonEncode(operation.id)};
window.__bahaMediaSuspended = false; true;
''');
        busy = false;
    }
    _emit();
  }

  void navigationFailed() {
    final failed = operation;
    _deadline?.cancel();
    operation = BrowserRequest(
      intent: failed.intent,
      animeId: failed.animeId,
      favoriteTarget: failed.favoriteTarget,
      query: failed.query,
      videoId: failed.videoId,
    );
    busy = false;
    browserError = browserVisible;
    if (showsPlayer) {
      playback.value = const PlaybackState(phase: PlaybackPhase.error);
    }
    if (operation.intent == BrowserIntent.detail) {
      detailLoading = false;
      detailFailed = true;
    }
    _emit();
  }

  Future<void> receive(
    String raw, {
    required Uri origin,
    required Uri source,
    required bool isMainFrame,
  }) async {
    final completed = operation;
    final body = completed.accept(
      raw,
      origin: origin,
      source: source,
      isMainFrame: isMainFrame,
    );
    if (body == null) return;
    if (body['type'] == 'player-state' || body['type'] == 'player-detail') {
      if (operation.videoId == null) {
        playingVideoId = body['videoId'] as String;
        operation = BrowserRequest(
          intent: BrowserIntent.play,
          id: completed.id,
          animeId: completed.animeId,
          videoId: playingVideoId,
        );
      }
      if (body['type'] == 'player-state') {
        playback.value = PlaybackState.fromJson(body);
      } else {
        playerDetail = AnimeDetail.fromJson(body['detail'] as Json);
        _emit();
      }
      return;
    }
    _deadline?.cancel();
    busy = false;
    switch (body['type']) {
      case 'catalog':
        for (final item in catalog.items) {
          if (item.poster != null) _posterIndex[item.id] = item.poster!;
        }
        final updated = _mergePosters(Catalog.fromJson(body));
        catalog = updated;
        catalogSource = 'live';
        verificationRequired = false;
        _emit();
        try {
          await cache.save(updated);
        } catch (_) {
          notice = t('storageError');
        }
        unawaited(_refreshPosters());
        if (operation.id == completed.id) {
          // Preserve a visible verification page until its user closes it.
          if (browserVisible) {
            _begin(BrowserIntent.browse);
          } else {
            await syncAccount();
          }
        }
      case 'search':
        searchResults = (body['items'] as List)
            .map((item) => Anime.fromJson(item as Json))
            .toList();
        searchedQuery = completed.query ?? '';
        _begin(BrowserIntent.idle);
      case 'detail':
        detail = AnimeDetail.fromJson(body['detail'] as Json);
        detailLoading = false;
        _begin(BrowserIntent.idle);
      case 'detail-error':
        detailLoading = false;
        detailFailed = true;
        _begin(BrowserIntent.idle);
      case 'account-synced':
        final previousOwner = accountProfile?.id.toLowerCase();
        accountProfile = body['profile'] == null
            ? null
            : AccountProfile.fromJson(body['profile'] as Json);
        if (previousOwner != accountProfile?.id.toLowerCase()) {
          _resetNotifications();
        }
        favorites = (body['favorites'] as List)
            .map((item) => Anime.fromJson(item as Json))
            .toList();
        history = (body['history'] as List)
            .map((item) => WatchEntry.fromJson(item as Json))
            .toList();
        accountSynced = true;
        accountNeedsRefresh = false;
        browserVisible = false;
        _begin(BrowserIntent.idle);
        if (catalog.items.isEmpty) await refreshCatalog();
      case 'account-guest':
        _resetNotifications();
        accountProfile = null;
        favorites = [];
        history = [];
        accountSynced = false;
        accountNeedsRefresh = false;
        if (browserVisible) {
          notice = t('accountHint');
        } else {
          _begin(BrowserIntent.idle);
        }
      case 'account-error':
      case 'favorite-error':
        notice = t('accountSyncError');
      case 'favorite-complete':
        notice = t(_desiredFavorite ? 'added' : 'removed');
        await syncAccount();
      case 'verification-required':
        verificationRequired = true;
        if (showsPlayer) {
          playback.value = const PlaybackState(
            phase: PlaybackPhase.verification,
          );
        }
        if (browserVisible) notice = t('officialVerificationHint');
    }
    _emit();
  }

  Future<void> _load(
    Uri uri,
    BrowserIntent intent, {
    required bool visible,
  }) async {
    if (!OfficialSite.allowedNavigation(uri)) return;
    _begin(intent);
    if (intent != BrowserIntent.play) {
      playerFullscreen = false;
      try {
        await _portal?.evaluate(
          '$_suspendMedia window.__bahaPlayerBridge?.dispose(); true;',
        );
      } catch (_) {}
    }
    browserVisible = visible;
    browserError = false;
    notice = null;
    busy = true;
    if (!visible) _armDeadline();
    _emit();
    if (_portal == null) {
      _pendingUri = uri;
    } else {
      await _portal!.load(uri);
    }
  }

  void _begin(BrowserIntent intent) {
    _deadline?.cancel();
    operation = BrowserRequest(
      intent: intent,
      animeId:
          const [
            BrowserIntent.detail,
            BrowserIntent.favorite,
            BrowserIntent.play,
          ].contains(intent)
          ? _pendingAnime?.id
          : null,
      favoriteTarget: intent == BrowserIntent.favorite
          ? _desiredFavorite
          : null,
      query: intent == BrowserIntent.search ? query : null,
      videoId: intent == BrowserIntent.play ? playingVideoId : null,
    );
  }

  void _armDeadline() {
    _deadline?.cancel();
    final expected = operation.id;
    _deadline = Timer(const Duration(seconds: 30), () {
      if (operation.id != expected) return;
      final account = const [
        BrowserIntent.account,
        BrowserIntent.accountRefresh,
      ].contains(operation.intent);
      navigationFailed();
      if (account) {
        notice = t('accountSyncError');
        _emit();
      }
    });
  }

  Future<void> _runScript(
    String name, [
    Map<String, String> replacements = const {},
  ]) async {
    var source = scripts[name];
    if (source == null || _portal == null) {
      navigationFailed();
      return;
    }
    for (final entry in replacements.entries) {
      source = source!.replaceAll(entry.key, entry.value);
    }
    final expected = operation.id;
    final prefix =
        '''
(function() {
const ticket = ${jsonEncode(expected)};
window.__bahaDocumentNonce = ticket;
function bahaPostJSON(raw) {
  const body = JSON.parse(raw); body.requestId = ticket;
  window.baha.postMessage(JSON.stringify(body));
}
if (document.querySelector('#challenge-form, #challenge-running, #cf-challenge-running') ||
    /^(Just a moment|Checking your browser)/i.test(document.title)) {
  bahaPostJSON(JSON.stringify({type:'verification-required'})); return;
}
''';
    try {
      if (operation.id == expected) {
        await _portal!.evaluate('$prefix\n$source\n})(); true;');
      }
    } catch (_) {
      if (operation.id == expected) navigationFailed();
    }
  }

  static const _suspendMedia = '''
window.__bahaMediaSuspended = true;
if (!window.__bahaPauseGuard) {
  document.addEventListener('play', function(event) {
    if (window.__bahaMediaSuspended && event.target instanceof HTMLMediaElement) event.target.pause();
  }, true);
  window.__bahaPauseGuard = true;
}
document.querySelectorAll('video,audio').forEach(function(media) { media.pause(); });
''';

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _deadline?.cancel();
    _searchDebounce?.cancel();
    _searchGeneration++;
    searchService.dispose();
    playback.dispose();
    super.dispose();
  }
}
