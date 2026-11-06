import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/browser_request.dart';
import '../core/models.dart';
import '../core/playback_state.dart';
import '../core/search_folding.dart';
import 'device_storage.dart';

abstract interface class OfficialPortal {
  Future<void> load(Uri uri);
  Future<void> reload();
  Future<void> goBack();
  Future<dynamic> evaluate(String script);
}

class AppStore extends ChangeNotifier {
  AppStore({
    required this.storage,
    required this.dictionaries,
    required this.folding,
    required this.scripts,
    this.language = 'zh-Hant',
    this.appearance = 'system',
    this.catalog = const Catalog(),
  }) : cache = CatalogCache(storage),
       catalogSource = catalog.items.isEmpty ? 'empty' : 'cache';

  static Future<AppStore> create({DeviceStorage? storage}) async {
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
    final scripts = <String, String>{};
    for (final name in [
      'catalog',
      'detail',
      'account-sync',
      'favorite-action',
      'player',
    ]) {
      scripts[name] = await rootBundle.loadString('assets/adapters/$name.js');
    }
    String? language, appearance;
    try {
      language = await disk.read('baha.device.language');
      appearance = await disk.read('baha.device.appearance');
    } catch (_) {
      // Missing device preferences must not prevent startup.
    }
    return AppStore(
      storage: disk,
      dictionaries: dictionaries,
      folding: SearchFolding(folding),
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
  String? _accountSyncDocument;

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
  String get query => _query;
  set query(String value) {
    if (value == _query) return;
    _query = value;
    searchedQuery = '';
    searchResults = [];
    _emit();
  }

  bool isFavorite(Anime item) => favorites.any((e) => e.id == item.id);
  List<Anime> get searchMatches {
    final result = catalog.items
        .where((e) => folding.matches(e.title, query))
        .toList();
    if (query.isNotEmpty && searchedQuery == query) {
      for (final item in searchResults) {
        if (!result.any((e) => e.id == item.id)) result.add(item);
      }
    }
    return result;
  }

  List<Anime> get libraryItems {
    final source = libraryFilter == 'favorites' ? favorites : searchMatches;
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
    if (_pendingUri != null) {
      final uri = _pendingUri!;
      _pendingUri = null;
      await portal.load(uri);
    } else {
      await refreshCatalog();
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
    if (query.trim().isEmpty) return;
    searchedQuery = query;
    await _load(
      OfficialSite.search(query),
      BrowserIntent.search,
      visible: false,
    );
  }

  Future<void> officialSearch() async {
    browserTitle = t('officialSearch');
    await _load(
      OfficialSite.search(query),
      BrowserIntent.browse,
      visible: true,
    );
  }

  Future<void> connectAccount() async {
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
        final updated = Catalog.fromJson(body);
        catalog = updated;
        catalogSource = 'live';
        verificationRequired = false;
        _emit();
        try {
          await cache.save(updated);
        } catch (_) {
          notice = t('storageError');
        }
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
        accountProfile = body['profile'] == null
            ? null
            : AccountProfile.fromJson(body['profile'] as Json);
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
    playback.dispose();
    super.dispose();
  }
}
