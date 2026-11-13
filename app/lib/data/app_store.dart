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
import 'official_app_api.dart';
import 'app_updates.dart';
import 'app_diagnostics.dart';
import 'native_http_api.dart';
import 'native_http_playback.dart';
import 'native_danmaku_sender.dart';
import 'native_account_api.dart';
import 'official_http_client.dart';

abstract interface class OfficialPortal {
  Future<void> load(Uri uri);
  Future<void> reload();
  Future<void> goBack();
  Future<dynamic> evaluate(String script);
}

class AppStore extends ChangeNotifier {
  // The desktop debug harness registers its own native video implementation.
  // Mobile builds do not include or initialize the desktop player packages.
  static const windowsNativePlaybackEnabled = bool.fromEnvironment(
    'BAHA_WINDOWS_NATIVE',
  );

  static String? get nativePlaybackBackend => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android-exoplayer',
    TargetPlatform.iOS => 'ios-avplayer',
    TargetPlatform.windows when windowsNativePlaybackEnabled => 'windows-mpv',
    _ => null,
  };
  AppStore({
    required this.storage,
    required this.dictionaries,
    required this.folding,
    required this.scripts,
    AnimeSearch? animeSearch,
    OfficialAppApi? metadataApi,
    AppUpdates? updates,
    AppDiagnostics? diagnostics,
    this.nativeHttpApiFactory,
    NativeDanmakuSender? danmakuSender,
    NativeAccountApi? accountApi,
    this.language = 'zh-Hant',
    this.appearance = 'system',
    this.catalog = const Catalog(),
  }) : danmakuSender = danmakuSender ?? NativeDanmakuSender(),
       accountApi = accountApi ?? NativeAccountApi(),
       searchService =
           animeSearch ??
           OfficialAnimeSearch(toTraditional: folding.toTraditional),
       updates = updates ?? AppUpdates(),
       metadataApi = metadataApi ?? OfficialAppApi(),
       diagnostics = diagnostics ?? AppDiagnostics.instance,
       cache = CatalogCache(storage),
       catalogSource = catalog.items.isEmpty ? 'empty' : 'cache' {
    if (searchService case final OfficialAnimeSearch search) {
      search.useTransport(
        (uri, {required useAccount}) =>
            this.metadataApi.fetchPublicCatalog(uri),
      );
    }
    playback.addListener(_recordPlayback);
  }

  static Future<AppStore> create({
    DeviceStorage? storage,
    AnimeSearch? animeSearch,
    OfficialAppApi? metadataApi,
    AppUpdates? updates,
    AppDiagnostics? diagnostics,
    NativeAccountApi? accountApi,
    NativeDanmakuSender? danmakuSender,
    NativeHttpApi Function()? nativeHttpApiFactory,
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
    for (final name in ['detail', 'account-sync']) {
      scripts[name] = await rootBundle.loadString('assets/adapters/$name.js');
    }
    String? language, appearance, danmaku, quality;
    try {
      language = await disk.read('baha.device.language');
      appearance = await disk.read('baha.device.appearance');
      danmaku = await disk.read('baha.device.danmaku');
      quality = await disk.read('baha.device.quality');
    } catch (_) {
      // Missing device preferences must not prevent startup.
    }
    final store = AppStore(
      storage: disk,
      dictionaries: dictionaries,
      folding: SearchFolding(folding, traditionalMapping: traditional),
      animeSearch: animeSearch,
      metadataApi: metadataApi,
      updates: updates,
      diagnostics: diagnostics,
      accountApi: accountApi,
      danmakuSender: danmakuSender,
      nativeHttpApiFactory: nativeHttpApiFactory,
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
    final preferredQuality = int.tryParse(quality ?? '');
    if (preferredQuality != null &&
        (preferredQuality == 0 ||
            (preferredQuality >= 144 && preferredQuality <= 4320))) {
      store._preferredQuality = preferredQuality;
    }
    try {
      if (danmaku != null) {
        store.danmakuSettings = DanmakuSettings.fromJson(
          jsonDecode(danmaku) as Json,
        );
      }
    } catch (_) {
      // A damaged device preference falls back to readable defaults.
    }
    final account = await AccountCache(disk).load();
    if (account != null) {
      store.accountProfile = account['profile'] == null
          ? null
          : AccountProfile.fromJson(account['profile'] as Json);
      store.favorites = (account['favorites'] as List)
          .map((item) => Anime.fromJson(item as Json))
          .toList();
      store.history = (account['history'] as List)
          .map((item) => WatchEntry.fromJson(item as Json))
          .toList();
      store.accountSynced = true;
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
  final OfficialAppApi metadataApi;
  final AppUpdates updates;
  final AppDiagnostics diagnostics;
  final NativeHttpApi Function()? nativeHttpApiFactory;
  final NativeDanmakuSender danmakuSender;
  final NativeAccountApi accountApi;
  int _accountGeneration = 0;
  int _accountSnapshotRevision = 0;
  bool accountLoading = false;
  (Anime, bool)? _favoriteAfterLogin;
  bool get favoriteLoginPending => _favoriteAfterLogin != null;
  NativeHttpPlayback? nativeHttpPlayback;
  bool get usesNativeHttpPlayback => nativeHttpPlayback != null && showsPlayer;
  String? _lastDiagnosticPlayback;
  DateTime? _lastDiagnosticSample;

  Map<String, Object?> get diagnosticContext {
    final state = playback.value;
    return {
      'language': language,
      'appearance': appearance,
      'operation': operation.intent.name,
      'backend': usesNativePlayback ? nativePlaybackBackend : 'webview',
      'foreground': applicationActive,
      'browserVisible': browserVisible,
      'phase': state.phase.name,
      'paused': state.paused,
      'buffering': state.buffering,
      'position': state.position,
      'duration': state.duration,
      'buffered': state.buffered,
      'rate': state.rate,
      'quality': state.quality,
    };
  }

  void _recordPlayback() {
    if (!diagnostics.enabled) return;
    final state = playback.value;
    final key =
        '${state.phase.name}/${state.paused}/${state.buffering}/'
        '${state.ended}/${state.quality}/${state.rate}';
    final now = DateTime.now();
    if (key == _lastDiagnosticPlayback &&
        _lastDiagnosticSample != null &&
        now.difference(_lastDiagnosticSample!) < const Duration(seconds: 10)) {
      return;
    }
    _lastDiagnosticPlayback = key;
    _lastDiagnosticSample = now;
    diagnostics.record('player.state', diagnosticContext);
  }

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
  bool get loggingOut => _logoutResult != null;
  bool get hasAccount => accountProfile != null || accountSynced;
  bool searching = false, searchFailed = false;
  int tab = 0;
  String libraryFilter = 'all', _query = '', searchedQuery = '';
  Anime? selectedAnime;
  AnimeDetail? detail;
  Anime? playingAnime;
  AnimeDetail? playerDetail;
  String? playingVideoId;
  bool get usesNativePlayback => usesNativeHttpPlayback;
  bool get applicationActive => _applicationActive;
  bool playerFullscreen = false;
  bool playerLocked = false;
  final playback = ValueNotifier<PlaybackState>(const PlaybackState());
  bool detailLoading = false, detailFailed = false;
  bool catalogLoading = false, catalogFailed = false;
  int _catalogGeneration = 0, _detailGeneration = 0;
  bool browserVisible = false, browserError = false, busy = false;
  bool verificationRequired = false, browserCanGoBack = false;
  String browserTitle = '';
  String? notice;
  Uri? browserUri;
  BrowserRequest operation = BrowserRequest(intent: BrowserIntent.idle);
  OfficialPortal? _portal;
  bool _portalHostActive = false;
  void setPortalHostActive(bool active) {
    _portalHostActive = active;
  }

  bool get needsOfficialPortal =>
      (browserVisible && !usesNativeHttpPlayback) ||
      (busy && !usesNativeHttpPlayback) ||
      _pendingUri != null ||
      (operation.intent == BrowserIntent.detail && detailLoading);
  Uri? _pendingUri;
  Anime? _pendingAnime;
  bool _disposed = false;
  bool _applicationActive = true;
  Timer? _deadline;
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  bool postersLoading = false;
  final _posterIndex = <String, String>{};
  String? _accountSyncDocument;
  Completer<bool>? _logoutResult;
  bool _logoutVerifying = false;
  Future<void>? _accountCacheWrite;
  int _preferredQuality = 0;
  Future<void> _qualityPreferenceWrite = Future<void>.value();
  PlaybackState? _lastGoodPlayback;
  Future<void> retryPlayback() => reloadBrowser();

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
    if (!_applicationActive || _disposed || loggingOut) {
      throw const CommunityException('unavailable');
    }
    final generation = _accountGeneration;
    final owner = accountProfile?.id.toLowerCase();
    final document = operation.id;
    void checkCurrent() {
      if (_disposed ||
          loggingOut ||
          !_applicationActive ||
          generation != _accountGeneration ||
          owner != accountProfile?.id.toLowerCase() ||
          (!communityReadActions.contains(action) &&
              document != operation.id)) {
        throw const CommunityException('stale');
      }
    }

    final result = await accountApi.community(action, {
      ...arguments,
      'owner': ?owner,
    }, checkCurrent: checkCurrent);
    if (result['ok'] != true) {
      throw CommunityException(result['code'] as String? ?? 'network');
    }
    return result;
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
        !usesNativeHttpPlayback ||
        !playback.value.canControl ||
        playingVideoId == null ||
        !DanmakuSettings.validMessage(text)) {
      throw const CommunityException('input');
    }
    if (!_communityWrites.add('danmaku')) {
      throw const CommunityException('busy');
    }
    final session = nativeHttpPlayback;
    final document = operation.id;
    final videoId = playingVideoId!;
    final owner = accountProfile?.id;
    try {
      if (owner == null || loggingOut) throw const CommunityException('login');
      void checkCurrent() {
        if (_disposed ||
            operation.id != document ||
            nativeHttpPlayback != session ||
            !showsPlayer ||
            playingVideoId != videoId ||
            accountProfile?.id.toLowerCase() != owner.toLowerCase()) {
          throw const CommunityException('stale');
        }
        if (!_applicationActive ||
            loggingOut ||
            !playback.value.canControl ||
            !danmakuSettings.enabled) {
          throw const CommunityException('unavailable');
        }
      }

      final item = await danmakuSender.send(
        videoId: videoId,
        owner: owner,
        text: text,
        color: color,
        position: position,
        size: size,
        checkCurrent: checkCurrent,
        currentPosition: () => playback.value.position,
      );
      if (!_disposed &&
          nativeHttpPlayback == session &&
          operation.id == document) {
        session?.addSentDanmaku(item);
      }
    } finally {
      _communityWrites.remove('danmaku');
    }
  }

  Future<void> setDanmakuSettings(DanmakuSettings value) async {
    danmakuSettings = value;
    _emit();
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
      notice = t('accountSyncError');
      _emit();
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
  int get preferredQuality => _preferredQuality;
  bool get simplified => language == 'zh-Hans';
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
    if (!value) playerLocked = false;
    _emit();
  }

  void setPlayerLocked(bool value) {
    if (playerLocked == value) return;
    playerLocked = value;
    _emit();
  }

  Future<void> dismissBrowser() async {
    if (showsPlayer && playerFullscreen) {
      if (playerLocked) return;
      setPlayerFullscreen(false);
    } else {
      await closeBrowser();
    }
  }

  Future<void> setApplicationActive(bool active) async {
    diagnostics.record('app.lifecycle', {'foreground': active});
    if (_applicationActive == active) return;
    _applicationActive = active;
    await nativeHttpPlayback?.setApplicationActive(active);
    if (active && !browserVisible && !busy && _portal != null) {
      await syncAccount();
    }
    _emit();
  }

  Future<void> controlPlayer(String action, [double? value]) async {
    diagnostics.record('player.command', {'action': action, 'value': value});
    if (!_applicationActive ||
        !browserVisible ||
        !showsPlayer ||
        (!playback.value.canOperate &&
            !(action == 'pause' && playback.value.surfaceReady)) ||
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
    Future<void>? preferenceWrite;
    if (action == 'quality') {
      if (value == null ||
          value != value.roundToDouble() ||
          (value != 0 && !playback.value.qualities.contains(value.toInt()))) {
        return;
      }
      _preferredQuality = value.toInt();
      final saved = _preferredQuality.toString();
      preferenceWrite = _qualityPreferenceWrite = _qualityPreferenceWrite.then(
        (_) => _savePreference('baha.device.quality', saved),
      );
    }
    try {
      await _sendPlayerCommand(action, value);
    } finally {
      if (preferenceWrite != null) await preferenceWrite;
    }
  }

  Future<bool> _sendPlayerCommand(String action, double? value) async =>
      await nativeHttpPlayback?.command(action, value) ?? false;

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
    diagnostics.record('app.tab', {'tab': value});
    tab = value;
    if (filter != null) {
      libraryFilter = filter;
      query = '';
    }
    _emit();
    if (value == 3 &&
        !browserVisible &&
        !busy &&
        (_portal != null || _portalHostActive)) {
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
    if (_pendingUri != null) {
      final uri = _pendingUri!;
      _pendingUri = null;
      await portal.load(uri);
    }
  }

  void detach(OfficialPortal portal) {
    if (!identical(_portal, portal)) return;
    _portal = null;
    browserUri = null;
    browserCanGoBack = false;
    _accountSyncDocument = null;
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
    if (usesNativeHttpPlayback) return;
    browserUri = uri;
    browserCanGoBack = canGoBack;
    _emit();
  }

  Future<void> refreshCatalog() async {
    if (_disposed || browserVisible) return;
    final generation = ++_catalogGeneration;
    catalogLoading = true;
    catalogFailed = false;
    _emit();
    try {
      final fetched = await metadataApi.fetchCatalog();
      if (_disposed || generation != _catalogGeneration) return;
      _rememberPosters(catalog.items);
      final updated = _mergePosters(fetched);
      catalog = updated;
      catalogSource = 'live';
      diagnostics.record('catalog.completed', {'count': updated.items.length});
      _emit();
      try {
        await cache.save(updated);
      } catch (_) {
        if (!_disposed && generation == _catalogGeneration) {
          notice = t('storageError');
        }
      }
      if (!_disposed && generation == _catalogGeneration) {
        unawaited(_refreshPosters());
      }
    } catch (_) {
      if (_disposed || generation != _catalogGeneration) return;
      catalogFailed = true;
      diagnostics.record('catalog.failed');
    } finally {
      if (!_disposed && generation == _catalogGeneration) {
        catalogLoading = false;
        _emit();
      }
    }
  }

  Future<void> openOfficial() async {
    browserTitle = t(
      verificationRequired ? 'officialVerification' : 'openOfficial',
    );
    await _load(OfficialSite.home, BrowserIntent.browse, visible: true);
  }

  Future<void> openDetail(Anime anime) async {
    if (_disposed) return;
    final generation = ++_detailGeneration;
    selectedAnime = anime;
    detail = null;
    detailLoading = true;
    detailFailed = false;
    _pendingAnime = anime;
    _emit();
    final videoId = anime.latestVideoId;
    if (videoId != null) {
      // Retire an older HTML detail request, while leaving playback/account
      // operations intact during an independent metadata read.
      if (operation.intent == BrowserIntent.detail) {
        _begin(BrowserIntent.idle);
        busy = false;
        _pendingUri = null;
      }
      try {
        final fetched = await metadataApi.fetchDetail(
          animeId: anime.id,
          videoId: videoId,
        );
        if (_disposed || generation != _detailGeneration) return;
        detail = fetched;
        diagnostics.record('detail.completed');
      } catch (_) {
        if (_disposed || generation != _detailGeneration) return;
        detailFailed = true;
        diagnostics.record('detail.failed');
      } finally {
        if (!_disposed && generation == _detailGeneration) {
          detailLoading = false;
          _emit();
        }
      }
      return;
    }
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
      diagnostics.record('search.completed', {'count': items.length});
      searchedQuery = input;
      _rememberPosters(items);
    } catch (_) {
      if (_disposed || generation != _searchGeneration || query != input) {
        return;
      }
      searchResults = [];
      searchFailed = true;
      diagnostics.record('search.failed');
    }
    if (generation == _searchGeneration) {
      searching = false;
      _emit();
    }
  }

  Future<void> connectAccount() async {
    if (loggingOut) return;
    _invalidateAccountRequests();
    _resetNotifications();
    accountProfile = null;
    favorites = [];
    history = [];
    accountSynced = false;
    unawaited(_saveAccountSnapshot(null));
    browserTitle = t('officialAccount');
    await _load(
      OfficialSite.home.resolve('mygather.php'),
      BrowserIntent.account,
      visible: true,
    );
  }

  Future<bool> logoutAccount() async {
    if (loggingOut || _disposed) return false;
    _favoriteAfterLogin = null;
    _invalidateAccountRequests();
    final result = Completer<bool>();
    _logoutResult = result;
    _logoutVerifying = false;
    browserTitle = t('logout');
    try {
      await _load(OfficialSite.logout, BrowserIntent.logout, visible: false);
      return await result.future;
    } catch (_) {
      if (_logoutResult == result) _finishLogout(false);
      return false;
    }
  }

  void _finishLogout(bool success) {
    final result = _logoutResult;
    if (result == null) return;
    _logoutResult = null;
    _logoutVerifying = false;
    _accountSyncDocument = null;
    _begin(BrowserIntent.idle);
    busy = false;
    result.complete(success);
    _emit();
  }

  Future<void> _receiveLogout(Json body) async {
    final result = _logoutResult;
    if (result == null) return;
    if (!_logoutVerifying || _accountSyncDocument != operation.id) return;
    if (body['type'] != 'account-guest') {
      if (body['type'] == 'verification-required') {
        verificationRequired = true;
      }
      _finishLogout(false);
      return;
    }
    _resetNotifications();
    accountProfile = null;
    favorites = [];
    history = [];
    accountSynced = false;
    accountNeedsRefresh = false;
    browserVisible = false;
    browserCanGoBack = false;
    _pendingUri = null;
    await _saveAccountSnapshot(null);
    if (_logoutResult == result) _finishLogout(true);
  }

  Future<void> toggleFavorite(Anime anime) async {
    final desired = !isFavorite(anime);
    if (accountProfile == null) {
      _favoriteAfterLogin = (anime, desired);
      await connectAccount();
      return;
    }
    await _setNativeFavorite(anime, desired);
  }

  Future<void> _setNativeFavorite(Anime anime, bool desired) async {
    final key = 'favorite:${anime.id}';
    if (loggingOut || _disposed || !_communityWrites.add(key)) return;
    final owner = accountProfile?.id.toLowerCase();
    final generation = _accountGeneration;
    try {
      await accountApi.setFavorite(
        anime,
        desired,
        owner: owner,
        checkCurrent: () {
          if (_disposed ||
              loggingOut ||
              !_applicationActive ||
              generation != _accountGeneration ||
              owner != accountProfile?.id.toLowerCase()) {
            throw const CommunityException('stale');
          }
        },
      );
      if (!_disposed &&
          generation == _accountGeneration &&
          owner == accountProfile?.id.toLowerCase()) {
        _confirmFavorite(anime, desired);
        _emit();
        unawaited(
          _saveAccountSnapshot({
            'profile': accountProfile?.toJson(),
            'favorites': favorites.map((item) => item.toJson()).toList(),
            'history': history.map((item) => item.toJson()).toList(),
          }),
        );
      }
    } on CommunityException catch (error) {
      if (!_disposed && generation == _accountGeneration) {
        if (error.code == 'login') {
          _favoriteAfterLogin = (anime, desired);
          await connectAccount();
          return;
        }
        notice = t(
          error.code == 'login'
              ? 'accountHint'
              : error.code == 'verification'
              ? 'officialVerificationHint'
              : 'accountSyncError',
        );
        _emit();
      }
    } finally {
      _communityWrites.remove(key);
    }
  }

  void _confirmFavorite(Anime anime, bool saved) {
    _accountSnapshotRevision++;
    favorites = [
      if (saved && !isFavorite(anime)) anime,
      ...favorites.where((item) => saved || item.id != anime.id),
    ];
    accountNeedsRefresh = true;
    notice = t(saved ? 'added' : 'removed');
  }

  Future<void> play(Anime anime, {Episode? episode}) async {
    _lastGoodPlayback = null;
    if (playingAnime?.id != anime.id) {
      playerDetail = selectedAnime?.id == anime.id ? detail : null;
    }
    playingAnime = anime;
    _pendingAnime = anime;
    browserTitle = anime.title;
    final videoId =
        episode?.id ??
        anime.latestVideoId ??
        playerDetail?.episodes.firstOrNull?.id;
    playingVideoId = videoId;
    playback.value = const PlaybackState();
    await _openNativeHttp(anime, videoId ?? '');
  }

  Future<void> _openNativeHttp(
    Anime anime,
    String videoId, {
    Json? checkpoint,
  }) async {
    final previous = nativeHttpPlayback;
    nativeHttpPlayback = null;
    _pendingUri = null;
    _begin(BrowserIntent.play);
    final document = operation.id;
    browserVisible = true;
    browserError = false;
    busy = false;
    notice = null;
    browserUri = null;
    verificationRequired = false;
    accountNeedsRefresh = true;
    nativeHttpPlayback = NativeHttpPlayback(
      document: document,
      videoId: videoId,
      preferredQuality: _preferredQuality,
      checkpoint: checkpoint,
      diagnostics: diagnostics,
      api: nativeHttpApiFactory?.call(),
      cookieLoader: OfficialHttpClient.loadPlaybackCookies,
      onState: (state) => updateNativePlayback(document, state),
    );
    final session = nativeHttpPlayback!;
    _emit();
    await previous?.close();
    if (_disposed || operation.id != document) {
      session.dispose();
      return;
    }
    unawaited(
      session.prepare(
        applicationActive: _applicationActive,
        nativeBackendAvailable: nativePlaybackBackend != null,
      ),
    );
    if (playerDetail == null && videoId.isNotEmpty) {
      unawaited(() async {
        try {
          final result = await metadataApi.fetchDetail(
            animeId: anime.id,
            videoId: videoId,
          );
          if (!_disposed && operation.id == document) {
            playerDetail = result;
            _emit();
          }
        } catch (_) {
          // A metadata failure cannot change the authorization session.
        }
      }());
    }
  }

  Future<void> continueWatching(WatchEntry entry) async {
    await play(
      entry.anime,
      episode: Episode(id: entry.videoId, label: entry.episodeLabel),
    );
  }

  Future<void> closeBrowser() async {
    if (operation.intent == BrowserIntent.account) _favoriteAfterLogin = null;
    _lastGoodPlayback = null;
    final http = nativeHttpPlayback;
    nativeHttpPlayback = null;
    final refreshAccount =
        accountNeedsRefresh || operation.intent == BrowserIntent.account;
    browserVisible = false;
    playerFullscreen = false;
    playerLocked = false;
    busy = false;
    _pendingUri = null;
    _begin(BrowserIntent.idle);
    final closing = operation.id;
    playback.value = const PlaybackState();
    _emit();
    await http?.close();
    await _releasePlayback(expected: closing, releaseSystemMedia: http != null);
    if (_disposed || operation.id != closing) return;
    if (refreshAccount) {
      await syncAccount();
    } else if (verificationRequired || catalog.items.isEmpty) {
      await refreshCatalog();
    }
    _emit();
  }

  Future<void> reloadBrowser() async {
    if (usesNativeHttpPlayback) {
      await _openNativeHttp(
        playingAnime!,
        playingVideoId ?? '',
        checkpoint: _lastGoodPlayback == null
            ? null
            : {
                'position': _lastGoodPlayback!.position,
                'rate': _lastGoodPlayback!.rate,
                'muted': _lastGoodPlayback!.muted,
                'paused': false,
              },
      );
      return;
    }
    _begin(operation.intent);
    browserError = false;
    notice = null;
    busy = true;
    _emit();
    final document = operation.id;
    try {
      await _portal?.reload().timeout(const Duration(seconds: 30));
    } catch (_) {
      if (!_disposed && operation.id == document) navigationFailed();
    }
  }

  Future<void> goBack() async => _portal?.goBack();

  Future<void> syncAccount({String? expectedOwner}) async {
    if (_disposed || loggingOut || accountLoading) return;
    final generation = _accountGeneration;
    final revision = _accountSnapshotRevision;
    accountLoading = true;
    try {
      final snapshot = await accountApi.fetchAccount(
        expectedOwner: expectedOwner,
        onAuthenticated: (raw) {
          if (_disposed ||
              loggingOut ||
              generation != _accountGeneration ||
              revision != _accountSnapshotRevision) {
            return;
          }
          _applyAccountProfile(AccountProfile.fromJson(raw));
          accountNeedsRefresh = true;
          _emit();
        },
        checkCurrent: () {
          if (_disposed || loggingOut || generation != _accountGeneration) {
            throw const CommunityException('stale');
          }
        },
      );
      if (_disposed || loggingOut || generation != _accountGeneration) return;
      if (revision != _accountSnapshotRevision) {
        accountNeedsRefresh = true;
        return;
      }
      if (snapshot == null && expectedOwner != null) {
        throw const CommunityException('login');
      }
      _applyAccountProfile(
        snapshot?['profile'] == null
            ? null
            : AccountProfile.fromJson(snapshot!['profile'] as Json),
      );
      favorites = [
        for (final raw in snapshot?['favorites'] as List? ?? [])
          Anime.fromJson(raw as Json),
      ];
      history = [
        for (final raw in snapshot?['history'] as List? ?? [])
          WatchEntry.fromJson(raw as Json),
      ];
      accountSynced = snapshot != null;
      accountNeedsRefresh = false;
      if (notice == t('accountSyncError')) notice = null;
      await _saveAccountSnapshot(
        snapshot == null
            ? null
            : {...snapshot, 'profile': accountProfile?.toJson()},
      );
    } on CommunityException catch (error) {
      if (!_disposed && generation == _accountGeneration) {
        accountNeedsRefresh = true;
        notice = t(
          error.code == 'verification'
              ? 'officialVerificationHint'
              : 'accountSyncError',
        );
      }
    } finally {
      if (!_disposed && generation == _accountGeneration) {
        accountLoading = false;
        _emit();
      }
    }
  }

  void _applyAccountProfile(AccountProfile? profile) {
    final previous = accountProfile;
    if (previous?.id.toLowerCase() != profile?.id.toLowerCase()) {
      _resetNotifications();
      favorites = [];
      history = [];
      accountSynced = false;
      unawaited(_saveAccountSnapshot(null));
    } else if (previous != null && profile != null) {
      profile = AccountProfile(
        id: profile.id,
        displayName: profile.displayName == profile.id
            ? previous.displayName
            : profile.displayName,
        avatar: profile.avatar ?? previous.avatar,
      );
    }
    accountProfile = profile;
  }

  void _invalidateAccountRequests() {
    _accountGeneration++;
    accountLoading = false;
    accountApi.invalidate();
  }

  void navigationStarted() {
    if (usesNativeHttpPlayback) return;
    if ((operation.intent == BrowserIntent.account ||
            operation.intent == BrowserIntent.logout) &&
        _accountSyncDocument == operation.id) {
      _begin(operation.intent);
      _accountSyncDocument = null;
      busy = true;
      _armDeadline();
      _emit();
    }
  }

  Future<void> navigationFinished(Uri? uri) async {
    if (usesNativeHttpPlayback) return;
    browserUri = uri;
    if (operation.intent == BrowserIntent.logout) {
      try {
        if (uri == null || !OfficialSite.allowedNavigation(uri)) {
          _finishLogout(false);
        } else if (!_logoutVerifying) {
          // The official endpoint can redirect to another Bahamut page.
          // Verify the resulting session in a fresh Anime account document.
          _logoutVerifying = true;
          await _load(
            OfficialSite.home.resolve('mygather.php'),
            BrowserIntent.logout,
            visible: false,
          );
        } else if (OfficialSite.trustedOrigin(uri) &&
            uri.path == '/mygather.php') {
          _accountSyncDocument = operation.id;
          await _runScript('account-sync', {'__BAHA_WATCH_ACCOUNT__': 'false'});
        } else {
          _finishLogout(false);
        }
      } catch (_) {
        _finishLogout(false);
      }
      return;
    }
    if (uri == null || !OfficialSite.trustedOrigin(uri)) {
      busy = false;
      _emit();
      return;
    }
    switch (operation.intent) {
      case BrowserIntent.detail:
        if (_pendingAnime != null) {
          await _runScript('detail', {'%ANIME_ID%': _pendingAnime!.id});
        }
      case BrowserIntent.account:
        _accountSyncDocument = operation.id;
        await _runScript('account-sync', {'__BAHA_WATCH_ACCOUNT__': 'true'});
      case BrowserIntent.logout:
        break;
      case BrowserIntent.idle:
      case BrowserIntent.browse:
        busy = false;
      case BrowserIntent.play:
        break;
    }
    _emit();
  }

  void navigationFailed() {
    if (usesNativeHttpPlayback) return;
    diagnostics.record('browser.failed', {'operation': operation.intent.name});
    if (operation.intent == BrowserIntent.logout) {
      _finishLogout(false);
      return;
    }
    final failed = operation;
    _deadline?.cancel();
    operation = BrowserRequest(
      intent: failed.intent,
      animeId: failed.animeId,
      videoId: failed.videoId,
    );
    busy = false;
    browserError = browserVisible;
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
    diagnostics.record('browser.result', {'type': body['type']});
    if (completed.intent == BrowserIntent.logout) {
      await _receiveLogout(body);
      return;
    }
    if (body['type'] == 'account-authenticated') {
      _invalidateAccountRequests();
      final profile = AccountProfile.fromJson(body['profile'] as Json);
      if (accountProfile?.id.toLowerCase() != profile.id.toLowerCase()) {
        _resetNotifications();
        favorites = [];
        history = [];
        accountSynced = false;
        unawaited(_saveAccountSnapshot(null));
      }
      accountProfile = profile;
      accountNeedsRefresh = true;
      browserVisible = false;
      busy = false;
      _pendingUri = null;
      _begin(BrowserIntent.idle);
      _emit();
      await syncAccount(expectedOwner: profile.id);
      final favorite = _favoriteAfterLogin;
      _favoriteAfterLogin = null;
      if (favorite != null && accountProfile != null) {
        await _setNativeFavorite(favorite.$1, favorite.$2);
      }
      return;
    }
    _deadline?.cancel();
    busy = false;
    switch (body['type']) {
      case 'detail':
        detail = AnimeDetail.fromJson(body['detail'] as Json);
        detailLoading = false;
        _begin(BrowserIntent.idle);
      case 'detail-error':
        detailLoading = false;
        detailFailed = true;
        _begin(BrowserIntent.idle);
      case 'account-guest':
        _resetNotifications();
        accountProfile = null;
        favorites = [];
        history = [];
        accountSynced = false;
        accountNeedsRefresh = false;
        unawaited(_saveAccountSnapshot(null));
        if (browserVisible) {
          notice = t('accountHint');
        } else {
          _begin(BrowserIntent.idle);
        }
      case 'account-error':
        notice = t('accountSyncError');
      case 'verification-required':
        verificationRequired = true;
        if (browserVisible) notice = t('officialVerificationHint');
    }
    _emit();
  }

  Future<void> _saveAccountSnapshot(Json? snapshot) {
    final previous = _accountCacheWrite;
    final write = () async {
      if (previous != null) await previous;
      try {
        await AccountCache(storage).save(snapshot);
      } catch (_) {
        // A cache failure must not interrupt the official session.
      }
    }();
    _accountCacheWrite = write;
    return write;
  }

  Future<void> _load(
    Uri uri,
    BrowserIntent intent, {
    required bool visible,
  }) async {
    if (!OfficialSite.allowedNavigation(uri)) return;
    final http = nativeHttpPlayback;
    nativeHttpPlayback = null;
    _begin(intent);
    final expected = operation.id;
    playerFullscreen = false;
    playerLocked = false;
    await http?.close();
    await _releasePlayback(
      expected: expected,
      releaseSystemMedia: http != null,
    );
    if (_disposed || operation.id != expected) return;
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
    diagnostics.record('browser.operation', {'intent': intent.name});
    if (loggingOut && intent != BrowserIntent.logout) _finishLogout(false);
    _deadline?.cancel();
    operation = BrowserRequest(
      intent: intent,
      animeId: const [BrowserIntent.detail, BrowserIntent.play].contains(intent)
          ? _pendingAnime?.id
          : null,
      videoId: intent == BrowserIntent.play ? playingVideoId : null,
    );
  }

  void _armDeadline() {
    _deadline?.cancel();
    final expected = operation.id;
    _deadline = Timer(const Duration(seconds: 30), () {
      if (operation.id != expected) return;
      diagnostics.record('browser.timeout', {
        'operation': operation.intent.name,
      });
      final account = operation.intent == BrowserIntent.account;
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

  static const _systemMedia = MethodChannel(
    'app.bahaplus.mobile/media_session',
  );

  Future<void> _releasePlayback({
    required String expected,
    required bool releaseSystemMedia,
  }) async {
    if (_disposed ||
        operation.id != expected ||
        !releaseSystemMedia ||
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      await _systemMedia.invokeMethod<void>('releasePlayback');
    } on PlatformException catch (error) {
      debugPrint('Unable to release system media session: ${error.code}');
    } on MissingPluginException {
      // Other hosts do not expose the iOS media session channel.
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void updateNativePlayback(String document, PlaybackState value) {
    if (_disposed ||
        operation.id != document ||
        !showsPlayer ||
        !browserVisible) {
      return;
    }
    if (value.canControl && !value.buffering) _lastGoodPlayback = value;
    playback.value = value;
  }

  @override
  void dispose() {
    _disposed = true;
    _catalogGeneration++;
    _detailGeneration++;
    nativeHttpPlayback?.dispose();
    danmakuSender.dispose();
    accountApi.dispose();
    metadataApi.dispose();
    _finishLogout(false);
    _deadline?.cancel();
    _searchDebounce?.cancel();
    _searchGeneration++;
    searchService.dispose();
    updates.dispose();
    playback.removeListener(_recordPlayback);
    playback.dispose();
    super.dispose();
  }
}
