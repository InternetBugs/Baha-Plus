import 'dart:async';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/browser_request.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../core/playback_state.dart';
import '../core/search_folding.dart';
import 'device_storage.dart';
import 'home_feed_builder.dart';
import 'preference_writer.dart';
import 'official_search.dart';
import 'official_app_api.dart';
import 'app_updates.dart';
import 'app_diagnostics.dart';
import 'native_http_api.dart';
import 'native_http_playback.dart';
import 'native_danmaku_sender.dart';
import 'native_account_api.dart';
import 'official_cookie_rotation.dart';
import 'official_http_client.dart';
import 'system_http.dart';

abstract interface class OfficialPortal {
  Future<void> load(Uri uri);
  Future<void> reload();
  Future<void> goBack();
  Future<dynamic> evaluate(String script);
}

extension _EpisodeCache<Value extends Object> on Map<String, Value> {
  Value? readRecent(String videoId) {
    final value = remove(videoId);
    if (value != null) this[videoId] = value;
    return value;
  }

  void storeRecent(String videoId, Value value, {required int limit}) {
    remove(videoId);
    this[videoId] = value;
    if (length > limit) remove(keys.first);
  }
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
    this.avatarEvictor,
    Future<String> Function(String)? scriptLoader,
    Future<void>? searchAssetsReady,
    this.language = 'zh-Hant',
    this.appearance = 'system',
    this.glassStyle = 'standard',
    this.catalog = const Catalog(),
  }) : danmakuSender = danmakuSender ?? NativeDanmakuSender(),
       accountApi = accountApi ?? NativeAccountApi(),
       searchService =
           animeSearch ??
           OfficialAnimeSearch(
             toTraditional: folding.toTraditional,
             foldingReady: searchAssetsReady,
           ),
       updates = updates ?? AppUpdates(),
       metadataApi = metadataApi ?? OfficialAppApi(),
       diagnostics = diagnostics ?? AppDiagnostics.instance,
       _scriptLoader = scriptLoader,
       _searchAssetsReady = searchAssetsReady,
       cache = CatalogCache(storage),
       catalogSource = catalog.items.isEmpty ? 'empty' : 'cache' {
    if (searchService case final OfficialAnimeSearch search) {
      search.useTransport(
        (uri, {required useAccount}) =>
            this.metadataApi.fetchPublicCatalog(uri),
        cancellable: (uri, {required useAccount, cancel}) =>
            this.metadataApi.fetchPublicCatalog(uri, cancel: cancel),
      );
    }
    playback.addListener(_recordPlayback);
    _captureScopes();
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
    Future<void> Function(String avatar)? avatarEvictor,
  }) async {
    final disk = storage ?? PreferencesStorage();
    Future<Map<String, String>> loadMap(String asset) async =>
        (jsonDecode(await rootBundle.loadString(asset)) as Json)
            .cast<String, String>();
    final (hans, hant, preferences, catalog, account) = await (
      loadMap('assets/i18n/zh-Hans.json'),
      loadMap('assets/i18n/zh-Hant.json'),
      _readPreferences(disk),
      CatalogCache(disk).load(),
      AccountCache(disk).load(),
    ).wait;
    final folding = <String, String>{};
    final traditional = <String, String>{};
    final language = preferences['baha.device.language'];
    final appearance = preferences['baha.device.appearance'];
    final danmaku = preferences['baha.device.danmaku'];
    final quality = preferences['baha.device.quality'];
    final glass = preferences['baha.device.glass'];
    final skipOpLongPress = preferences['baha.device.skipOpLongPress'];
    final skipAgeConfirmation = preferences['baha.device.skipAgeConfirmation'];
    final scripts = <String, String>{};
    final scriptLoads = <String, Future<String>>{};
    Future<String> loadScript(String name) {
      if (scripts[name] case final script?) return Future.value(script);
      return scriptLoads.putIfAbsent(name, () async {
        try {
          return scripts[name] = await rootBundle.loadString(
            'assets/adapters/$name.js',
          );
        } finally {
          scriptLoads.remove(name);
        }
      });
    }

    final searchAssetsReady = Future<void>(() async {
      final maps = await Future.wait([
        loadMap('assets/data/search-folding.json'),
        loadMap('assets/data/search-traditional.json'),
      ]);
      folding.addAll(maps.first);
      traditional.addAll(maps.last);
    }).catchError((Object _) {});
    final store = AppStore(
      storage: disk,
      dictionaries: {'zh-Hans': hans, 'zh-Hant': hant},
      folding: SearchFolding(folding, traditionalMapping: traditional),
      animeSearch: animeSearch,
      metadataApi: metadataApi,
      updates: updates,
      diagnostics: diagnostics,
      accountApi: accountApi,
      danmakuSender: danmakuSender,
      nativeHttpApiFactory: nativeHttpApiFactory,
      scripts: scripts,
      avatarEvictor: avatarEvictor,
      scriptLoader: loadScript,
      searchAssetsReady: searchAssetsReady,
      language: const ['zh-Hans', 'zh-Hant'].contains(language)
          ? language!
          : languageForSystem(
              PlatformDispatcher.instance.locale.toLanguageTag(),
            ),
      appearance: const ['system', 'light', 'dark'].contains(appearance)
          ? appearance!
          : 'system',
      glassStyle: const ['performance', 'standard', 'premium'].contains(glass)
          ? glass!
          : 'standard',
      catalog: catalog ?? const Catalog(),
    );
    final preferredQuality = int.tryParse(quality ?? '');
    if (preferredQuality != null &&
        (preferredQuality == 0 ||
            (preferredQuality >= 144 && preferredQuality <= 4320))) {
      store._preferredQuality = preferredQuality;
    }
    store._skipOpLongPress =
        skipOpLongPress != '0' && skipOpLongPress != 'false';
    store._skipAgeConfirmation = skipAgeConfirmation == '1';
    try {
      if (danmaku != null) {
        store.danmakuSettings = DanmakuSettings.fromJson(
          jsonDecode(danmaku) as Json,
        );
      }
    } catch (_) {
      // A damaged device preference falls back to readable defaults.
    }
    if (account != null) {
      store.accountProfile = account.profile;
      if (store.accountProfile != null) {
        store._profileCheckedAt = account.profileCheckedAt;
      }
      store.favorites = account.favorites;
      store.history = account.history;
      store.accountSynced = account.collectionsSynced;
      store.accountNeedsRefresh = !store.accountSynced;
    }
    unawaited(
      searchAssetsReady.then((_) {
        if (store._disposed) return;
        store.folding.clearCache();
        store._libraryQueryCache = null;
        store.libraryFilterNotifier.value++;
      }),
    );
    unawaited(
      Future<void>(() async {
        if (store._disposed) return;
        await Future.wait([loadScript('detail'), loadScript('account-sync')]);
      }).catchError((Object _) {}),
    );
    store._captureScopes();
    return store;
  }

  static const _preferenceKeys = {
    'baha.device.language',
    'baha.device.appearance',
    'baha.device.danmaku',
    'baha.device.quality',
    'baha.device.glass',
    'baha.device.skipOpLongPress',
    'baha.device.skipAgeConfirmation',
  };

  static Future<Map<String, String>> _readPreferences(
    DeviceStorage disk,
  ) async {
    if (disk is BatchDeviceStorage) {
      try {
        return await disk.readAll(_preferenceKeys);
      } catch (_) {}
    }
    final values = await Future.wait([
      for (final key in _preferenceKeys)
        () async {
          try {
            return await disk.read(key);
          } catch (_) {
            return null;
          }
        }(),
    ]);
    return {
      for (final (index, key) in _preferenceKeys.indexed) key: ?values[index],
    };
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
  final Future<void> Function(String avatar)? avatarEvictor;
  final Future<String> Function(String name)? _scriptLoader;
  final Future<void>? _searchAssetsReady;
  Future<void> ensureSearchAssets() => _searchAssetsReady ?? Future.value();
  late final _preferences = PreferenceWriter(
    storage,
    onError: () {
      if (_disposed) return;
      notice = t('storageError');
      _emit();
    },
  );
  int _accountGeneration = 0;
  int _accountSnapshotRevision = 0;
  // A newer identity observation supersedes a pending guest confirmation,
  // even when a collection sync authenticates the same owner again.
  int _accountIdentityRevision = 0;
  bool accountLoading = false;
  (Anime, bool)? _favoriteAfterLogin;
  bool get favoriteLoginPending => _favoriteAfterLogin != null;
  NativeHttpPlayback? nativeHttpPlayback;
  Future<void>? _playbackRelease;
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
  String language, appearance, glassStyle;
  Catalog catalog;
  String catalogSource;
  List<Anime> favorites = [], searchResults = [];
  List<WatchEntry> history = [];
  AccountProfile? accountProfile;
  int accountPortraitVersion = 0;
  int? _profileCheckedAt;
  bool _profileRefreshing = false;
  bool get profileRefreshing => _profileRefreshing;
  bool accountSynced = false, accountNeedsRefresh = false;
  bool get loggingOut => _loggingOut;
  bool get hasAccount => accountProfile != null || accountSynced;
  bool searching = false, searchFailed = false;
  int tab = 0;
  String _libraryFilter = 'all',
      _query = '',
      _libraryQuery = '',
      searchedQuery = '';
  String get libraryFilter => _libraryFilter;
  set libraryFilter(String value) {
    if (_libraryFilter == value) return;
    _libraryFilter = value;
    _emitLibraryFilter();
  }

  Anime? selectedAnime;
  AnimeDetail? detail;
  Anime? playingAnime;
  AnimeDetail? playerDetail;
  String? playingVideoId;
  bool get usesNativePlayback => usesNativeHttpPlayback;
  bool get applicationActive => _applicationActive;
  bool get playbackActive => _applicationActive || _pictureInPicturePlayback;
  bool playerFullscreen = false;
  bool playerLocked = false;
  final playback = ValueNotifier<PlaybackState>(const PlaybackState());
  bool detailLoading = false, detailFailed = false;
  bool catalogLoading = false, catalogFailed = false;
  String? catalogError;
  bool _catalogNeedsRetryOnResume = false;
  int _catalogGeneration = 0, _detailGeneration = 0;
  Future<void> _catalogCacheWrite = Future.value();
  final _detailCache = <String, (AnimeDetail, DateTime)>{};
  bool browserVisible = false, browserError = false, busy = false;
  bool verificationRequired = false, browserCanGoBack = false;
  String browserTitle = '';
  String? _notice;
  int _noticeRevision = 0;
  final noticeEvents = ValueNotifier<int>(0);
  String? get notice => _notice;
  int get noticeRevision => _noticeRevision;
  set notice(String? value) {
    _notice = value;
    if (value != null && value.isNotEmpty) {
      _noticeRevision++;
      if (!_disposed) noticeEvents.value = _noticeRevision;
    }
  }

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
  bool _pictureInPicturePlayback = false;
  Timer? _deadline;
  Timer? _searchDebounce;
  Completer<void>? _searchCancel,
      _detailCancel,
      _playerDetailCancel,
      _libraryCancel;
  int _searchGeneration = 0;
  bool postersLoading = false;
  final _posterIndex = <String, String>{};
  final _posterLookupsAttempted = <String>{};
  int _posterGeneration = 0;
  String? _accountSyncDocument;
  bool _loggingOut = false;
  Future<void>? _accountCacheWrite;
  int _preferredQuality = 0;
  bool _skipOpLongPress = true;
  bool _skipAgeConfirmation = false;
  PlaybackState? _lastGoodPlayback;
  Future<void> retryPlayback() => reloadBrowser();

  final danmakuSettingsNotifier = ValueNotifier(const DanmakuSettings());
  DanmakuSettings get danmakuSettings => danmakuSettingsNotifier.value;
  set danmakuSettings(DanmakuSettings value) =>
      danmakuSettingsNotifier.value = value;
  final searchNotifier = ValueNotifier(0);
  final libraryFilterNotifier = ValueNotifier(0);
  final detailNotifier = ValueNotifier(0);
  final notificationsNotifier = ValueNotifier(0);
  final accountNotifier = ValueNotifier(0);
  final browserNotifier = ValueNotifier(0);
  final catalogNotifier = ValueNotifier(0);
  List<AnimeNotification> notifications = [];
  final Set<String> _readNotifications = {};
  int _readRevision = 0;
  List<AnimeNotification>? _unreadNotificationsSource;
  int _unreadNotificationsLength = -1;
  int _unreadReadRevision = -1;
  int _unreadNotificationsCache = 0;
  bool notificationsLoading = false;
  String? notificationsError;
  int _notificationGeneration = 0;
  final Set<String> _communityWrites = {};
  final commentsVersion = ValueNotifier<int>(0);
  final _commentPreviewCache = <String, (CommentPage, DateTime)>{};
  final _commentPreviewRequests = <String, Object>{};
  final _commentDrafts = <String, CommentDraft>{};
  int _commentAccountRevision = 0;

  int get unreadNotifications {
    if (!identical(_unreadNotificationsSource, notifications) ||
        _unreadNotificationsLength != notifications.length ||
        _unreadReadRevision != _readRevision) {
      var count = 0;
      for (final item in notifications) {
        if (!_readNotifications.contains(item.id)) count++;
      }
      _unreadNotificationsCache = count;
      _unreadNotificationsSource = notifications;
      _unreadNotificationsLength = notifications.length;
      _unreadReadRevision = _readRevision;
    }
    return _unreadNotificationsCache;
  }

  bool notificationRead(AnimeNotification item) =>
      _readNotifications.contains(item.id);

  Future<Json> community(String action, Json arguments) =>
      _community(action, arguments, models: false);

  Future<Json> _community(
    String action,
    Json arguments, {
    bool models = true,
  }) async {
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

    final send = models ? accountApi.communityModels : accountApi.community;
    final result = await send(action, {
      ...arguments,
      'owner': ?owner,
    }, checkCurrent: checkCurrent);
    if (result['ok'] != true) {
      throw CommunityException(result['code'] as String? ?? 'network');
    }
    return result;
  }

  CommentPage? cachedComments(String videoId, {int? order, int? sort}) {
    if (sort != null) return _cachedRecentComment(_commentKey(videoId, sort));
    if (order != null && order != 1) return null;
    return _cachedRecentComment(videoId) ??
        (order == null ? _cachedRecentComment(_commentKey(videoId, 0)) : null);
  }

  String _commentKey(String videoId, int sort) =>
      sort == 1 ? videoId : '$videoId:$sort';

  CommentPage? _cachedRecentComment(String key) {
    final entry = _commentPreviewCache.readRecent(key);
    if (entry == null) return null;
    if (!DateTime.now().isBefore(entry.$2)) {
      _commentPreviewCache.remove(key);
      return null;
    }
    return entry.$1;
  }

  void _storeCommentPage(String key, CommentPage page) =>
      _commentPreviewCache.storeRecent(key, (
        page,
        DateTime.now().add(const Duration(minutes: 2)),
      ), limit: 20);

  void updateCachedCommentPage(String videoId, int sort, CommentPage page) {
    if (_disposed) return;
    final key = _commentKey(videoId, sort);
    _commentPreviewRequests.remove(key);
    _storeCommentPage(key, page);
    commentsVersion.value++;
  }

  void updateCachedCommentsPage(
    String videoId,
    CommentPage page, {
    int order = 1,
  }) {
    if (order == 1) updateCachedCommentPage(videoId, order, page);
  }

  void invalidateCommentsCache([String? videoId]) {
    if (videoId == null) {
      _commentPreviewRequests.clear();
      _commentPreviewCache.clear();
    } else {
      _commentPreviewRequests.removeWhere(
        (key, _) => _isCommentKey(key, videoId),
      );
      _commentPreviewCache.removeWhere((key, _) => _isCommentKey(key, videoId));
    }
    if (!_disposed) commentsVersion.value++;
  }

  bool _isCommentKey(String key, String videoId) =>
      key == videoId || key.startsWith('$videoId:');

  CommentDraft commentDraft(String videoId) =>
      _commentDrafts.readRecent(videoId) ?? const CommentDraft();

  void saveCommentDraft(String videoId, CommentDraft draft) {
    if (draft.isEmpty) {
      clearCommentDraft(videoId);
    } else if (!_disposed) {
      _commentDrafts.storeRecent(videoId, draft, limit: 30);
    }
  }

  void clearCommentDraft(String videoId) => _commentDrafts.remove(videoId);

  void _resetAccountComments() {
    _commentAccountRevision++;
    _commentDrafts.clear();
    _commentPreviewRequests.clear();
    if (_commentPreviewCache.isNotEmpty) invalidateCommentsCache();
  }

  Future<CommentPage> loadComments(
    String videoId, {
    int order = 1,
    int page = 0,
    int? sort,
  }) async {
    final selectedOrder = sort ?? order;
    final key = _commentKey(videoId, selectedOrder);
    final generation = _accountGeneration;
    final owner = accountProfile?.id.toLowerCase();
    final request = (sort != null || order == 1) && page == 0 ? Object() : null;
    if (request != null) _commentPreviewRequests[key] = request;
    try {
      final raw = await _community('comments', {
        'videoId': videoId,
        'order': selectedOrder,
        'page': page,
      });
      final result = switch (raw['comments']) {
        final List<OfficialComment> comments => CommentPage(
          messageId: raw['messageId'] as String,
          total: raw['total'] as int,
          nextPage: raw['nextPage'] as int,
          comments: comments,
        ),
        _ => CommentPage.fromJson(raw),
      };
      if (request != null &&
          _commentPreviewRequests[key] == request &&
          !_disposed &&
          generation == _accountGeneration &&
          owner == accountProfile?.id.toLowerCase()) {
        _storeCommentPage(key, result);
      }
      return result;
    } finally {
      if (request != null && _commentPreviewRequests[key] == request) {
        _commentPreviewRequests.remove(key);
      }
    }
  }

  Future<List<OfficialComment>> loadReplies(String commentId) async {
    final raw = (await _community('replies', {
      'commentId': commentId,
    }))['comments'];
    return raw is List<OfficialComment>
        ? raw
        : CommentPage.parseComments(raw, maxItems: 2000);
  }

  Future<void> _writeCommunity(
    String key,
    String action,
    Json arguments,
  ) async {
    if (!_communityWrites.add(key)) throw const CommunityException('busy');
    try {
      await _community(action, arguments);
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
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.runes.length > 2000) {
      throw const CommunityException('input');
    }
    final revision = _commentAccountRevision;
    await _writeCommunity('comment:$messageId', 'comment-send', {
      'videoId': videoId,
      'messageId': messageId,
      'text': trimmed,
      'commentId': ?commentId,
    });
    if (_disposed || revision != _commentAccountRevision) return;
    if (commentId == null) {
      invalidateCommentsCache(videoId);
    } else {
      _commentPreviewRequests.removeWhere(
        (key, _) => _isCommentKey(key, videoId),
      );
      for (final key
          in _commentPreviewCache.keys
              .where((key) => _isCommentKey(key, videoId))
              .toList()) {
        _changeCachedComment(
          key,
          commentId,
          (comment) => comment.copyWith(replies: comment.replies + 1),
        );
      }
      commentsVersion.value++;
    }
  }

  bool _changeCachedComment(
    String key,
    String commentId,
    OfficialComment Function(OfficialComment) change,
  ) {
    final page = _cachedRecentComment(key);
    if (page == null) return false;
    final index = page.comments.indexWhere(
      (comment) => comment.id == commentId,
    );
    if (index < 0) return false;
    final comments = page.comments.toList(growable: false);
    comments[index] = change(comments[index]);
    _storeCommentPage(key, page.copyWith(comments: comments));
    return true;
  }

  Future<OfficialComment> voteComment(
    OfficialComment comment,
    int type, {
    String? videoId,
  }) async {
    final revision = _commentAccountRevision;
    await _writeCommunity('vote:${comment.id}', 'comment-vote', {
      'commentId': comment.id,
      'type': type,
      'remove': comment.vote == (type == 1 ? 1 : -1),
    });
    final updated = comment.withVote(type);
    if (_disposed || revision != _commentAccountRevision) return updated;
    final episodes = videoId == null
        ? _commentPreviewCache.keys.toList()
        : _commentPreviewCache.keys
              .where((key) => _isCommentKey(key, videoId))
              .toList();
    var changed = false;
    for (final episode in episodes) {
      if (_changeCachedComment(episode, comment.id, (_) => updated)) {
        _commentPreviewRequests.remove(episode);
        changed = true;
      }
    }
    if (changed) commentsVersion.value++;
    return updated;
  }

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

  Future<void> setDanmakuSettings(DanmakuSettings value) {
    if (_disposed || danmakuSettings == value) return Future.value();
    danmakuSettings = value;
    return _preferences.write(
      'baha.device.danmaku',
      jsonEncode(value.toJson()),
      debounce: const Duration(milliseconds: 200),
    );
  }

  Future<void> refreshNotifications() async {
    if (notificationsLoading) return;
    final generation = ++_notificationGeneration;
    final owner = accountProfile?.id.toLowerCase();
    notificationsLoading = true;
    notificationsError = null;
    diagnostics.record('notifications.started');
    _emit();
    try {
      final result = await _community('notifications', {});
      if (_disposed || generation != _notificationGeneration) return;
      final actualOwner = result['owner'] as String;
      if (actualOwner.isEmpty || (owner != null && actualOwner != owner)) {
        throw const CommunityException('login');
      }
      final raw = result['items'] as List;
      if (raw.length > 200) {
        throw const FormatException('Too many notifications');
      }
      final items = raw is List<AnimeNotification>
          ? raw
          : raw
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
            (jsonDecode(stored) as List)
                .cast<String>()
                .take(500)
                .toList()
                .reversed,
          );
        } catch (_) {}
      }
      for (final id in currentRead) {
        _readNotifications.remove(id);
        _readNotifications.add(id);
      }
      _trimReadNotifications();
      _readRevision++;
      notifications = items;
      _notificationOwner = actualOwner;
      diagnostics.record('notifications.completed', {'count': items.length});
    } catch (error, stack) {
      if (_disposed || generation != _notificationGeneration) return;
      notificationsError = error is CommunityException ? error.code : 'network';
      diagnostics.record('notifications.failed', {
        'code': notificationsError,
        'type': error.runtimeType.toString(),
        'stack': stack.toString().split('\n').take(12).toList(),
      });
      if (notificationsError == 'login') {
        notifications = [];
        _readNotifications.clear();
        _readRevision++;
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
    for (final id
        in item == null ? notifications.map((e) => e.id) : [item.id]) {
      _readNotifications.remove(id);
      _readNotifications.add(id);
    }
    _trimReadNotifications();
    _readRevision++;
    _emit();
    final read = jsonEncode(
      _readNotifications.toList().reversed.take(500).toList(),
    );
    await _writeAccountData(
      () => storage.write('baha.notifications.read.$owner', read),
    );
  }

  void _trimReadNotifications() {
    final overflow = _readNotifications.length - 500;
    if (overflow > 0) {
      _readNotifications.removeAll(_readNotifications.take(overflow).toList());
    }
  }

  Future<void> openNotification(AnimeNotification item) async {
    await markNotificationsRead(item);
    // Resolve the real series ID; a video ID must never be used as a series ID.
    try {
      final detail = await _community('notification-target', {
        'videoId': item.videoId,
      });
      final raw = detail['anime'];
      final anime = raw is Anime ? raw : Anime.fromJson(raw as Json);
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
    _readRevision++;
    _notificationOwner = null;
    notificationsLoading = false;
    notificationsError = null;
  }

  String t(String key) => dictionaries[language]?[key] ?? key;
  int get preferredQuality => _preferredQuality;
  bool get skipOpLongPress => _skipOpLongPress;
  bool get skipAgeConfirmation => _skipAgeConfirmation;
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

  Future<void> setApplicationActive(
    bool active, {
    bool pictureInPicture = false,
  }) async {
    final foregroundChanged = _applicationActive != active;
    if (!foregroundChanged && _pictureInPicturePlayback == pictureInPicture) {
      return;
    }
    final wasPlaybackActive = playbackActive;
    if (foregroundChanged) {
      diagnostics.record('app.lifecycle', {'foreground': active});
    }
    _applicationActive = active;
    _pictureInPicturePlayback = pictureInPicture;
    if (foregroundChanged && active) SystemHttpOverrides.clearProxyCache();
    if (playbackActive != wasPlaybackActive) {
      await nativeHttpPlayback?.setApplicationActive(playbackActive);
    }
    final returning = foregroundChanged && active && _applicationActive;
    final profileRefresh = returning ? refreshAccountProfile() : null;
    if (returning &&
        !browserVisible &&
        !busy &&
        (_portal != null || _portalHostActive)) {
      await syncAccount();
    }
    if (returning &&
        (_catalogNeedsRetryOnResume || catalogFailed) &&
        !browserVisible &&
        !catalogLoading) {
      _catalogNeedsRetryOnResume = false;
      unawaited(refreshCatalog());
    }
    await profileRefresh;
    _emit();
  }

  Future<void> controlPlayer(String action, [double? value]) async {
    diagnostics.record('player.command', {'action': action, 'value': value});
    if (!playbackActive ||
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
      preferenceWrite = _savePreference(
        'baha.device.quality',
        _preferredQuality.toString(),
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

  Catalog? _derivedCatalog;
  late HomeFeedBuilder _homeFeedBuilder;
  List<Anime>? _favoriteIdsSource;
  int _favoriteIdsLength = -1;
  Set<String> _favoriteIds = const {};
  Catalog? _libraryCatalog;
  List<Anime>? _libraryFavorites;
  int _libraryFavoritesLen = -1;
  String? _libraryFilterCache;
  String? _libraryQueryCache;
  List<Anime> _libraryItemsCache = const [];
  final _libraryPages = <String, Anime>{};
  List<Anime>? _libraryMergedItems;
  Catalog? _libraryMergeSource;
  int _nextLibraryPage = 1;
  int _libraryGeneration = 0;
  bool _libraryCatalogLoading = false;
  bool _libraryCatalogHasMore = true;
  String? _libraryCatalogError;

  List<Anime> get libraryCatalogItems {
    if (_libraryMergedItems != null &&
        identical(_libraryMergeSource, catalog)) {
      return _libraryMergedItems!;
    }
    final items = {for (final item in catalog.items) item.id: item};
    for (final item in _libraryPages.values) {
      items.putIfAbsent(item.id, () => item);
    }
    _libraryMergeSource = catalog;
    return _libraryMergedItems = List.unmodifiable(items.values);
  }

  bool get libraryCatalogLoading => _libraryCatalogLoading;
  bool get libraryCatalogHasMore => _libraryCatalogHasMore;
  String? get libraryCatalogError => _libraryCatalogError;

  Future<void> loadMoreLibraryCatalog({bool reset = false}) async {
    if (_disposed) return;
    if (reset) {
      _libraryCancel?.complete();
      _libraryPages.clear();
      _libraryMergedItems = null;
      _libraryCatalog = null;
      _nextLibraryPage = 1;
      _libraryCatalogHasMore = true;
    } else if (_libraryCatalogLoading || !_libraryCatalogHasMore) {
      return;
    }
    final generation = ++_libraryGeneration;
    final cancel = _libraryCancel = Completer<void>();
    _libraryCatalogLoading = true;
    _libraryCatalogError = null;
    _emitLibraryFilter();
    try {
      final result = await metadataApi.fetchLibraryPage(
        _nextLibraryPage,
        cancel: cancel.future,
      );
      if (_disposed || generation != _libraryGeneration) return;
      for (final item in result.items) {
        _libraryPages.putIfAbsent(item.id, () => item);
      }
      _libraryMergedItems = null;
      _libraryCatalog = null;
      _nextLibraryPage++;
      _libraryCatalogHasMore = result.hasMore;
    } on UnsupportedError {
      if (generation == _libraryGeneration) _libraryCatalogHasMore = false;
    } catch (error) {
      if (generation == _libraryGeneration) {
        _libraryCatalogError = error is OfficialAppApiException
            ? error.code
            : 'network';
      }
    } finally {
      if (!_disposed && generation == _libraryGeneration) {
        _libraryCancel = null;
        _libraryCatalogLoading = false;
        _emitLibraryFilter();
      }
    }
  }

  HomeFeedBuilder get _catalogSections {
    if (!identical(_derivedCatalog, catalog)) {
      _homeFeedBuilder = HomeFeedBuilder(catalog);
      _derivedCatalog = catalog;
    }
    return _homeFeedBuilder;
  }

  HomeFeed get homeFeed => _catalogSections.feed;
  List<Anime> get seasonal => _catalogSections.seasonal;
  List<Anime> get seasonalPopular => _catalogSections.seasonalPopular;
  List<Anime> get popular => _catalogSections.popular;
  List<Anime> get newAdded => _catalogSections.newAdded;
  List<AnimeCollection> get thematicCollections =>
      _catalogSections.thematicCollections;
  AnimeCollection? get expiringCollection =>
      _catalogSections.expiringCollection;

  bool get _usesOfficialSearch => tab == 4;
  String get query => _query;
  set query(String value) {
    if (value == _query) return;
    _query = value;
    searchedQuery = '';
    searchResults = [];
    _searchDebounce?.cancel();
    _searchCancel?.complete();
    _searchCancel = null;
    _searchGeneration++;
    searching = value.trim().isNotEmpty && _usesOfficialSearch;
    searchFailed = false;
    _emitSearch();
    if (searching) {
      _searchDebounce = Timer(
        const Duration(milliseconds: 350),
        () => unawaited(search()),
      );
    }
  }

  String get libraryQuery => _libraryQuery;
  set libraryQuery(String value) {
    if (value == _libraryQuery) return;
    _libraryQuery = value;
    _emitLibraryFilter();
  }

  void openGlobalSearch(String term) {
    final trimmed = term.trim();
    tab = 4;
    if (trimmed.isEmpty) {
      query = '';
      _emit();
      return;
    }
    if (_query == trimmed) {
      if (searchedQuery != trimmed && !searching) {
        unawaited(search());
      } else {
        _emit();
      }
      return;
    }
    query = trimmed;
    unawaited(search());
  }

  bool isFavorite(Anime item) {
    if (!identical(_favoriteIdsSource, favorites) ||
        _favoriteIdsLength != favorites.length) {
      _favoriteIds = {for (final entry in favorites) entry.id};
      _favoriteIdsSource = favorites;
      _favoriteIdsLength = favorites.length;
    }
    return _favoriteIds.contains(item.id);
  }

  List<Anime> get searchMatches {
    if (query.trim().isEmpty) return catalog.items;
    return searchedQuery == query ? searchResults : [];
  }

  List<Anime> get libraryItems {
    if (identical(_libraryCatalog, catalog) &&
        identical(_libraryFavorites, favorites) &&
        _libraryFavoritesLen == favorites.length &&
        _libraryFilterCache == libraryFilter &&
        _libraryQueryCache == _libraryQuery) {
      return _libraryItemsCache;
    }
    final source = switch (libraryFilter) {
      'favorites' => favorites,
      'all' => libraryCatalogItems,
      _ => catalog.items,
    };
    final filterSection =
        libraryFilter != 'all' && libraryFilter != 'favorites';
    final normalizedQuery = folding.normalizeQuery(_libraryQuery);
    final result = List<Anime>.unmodifiable([
      for (final item in source)
        if ((!filterSection || item.sections.contains(libraryFilter)) &&
            (normalizedQuery.isEmpty ||
                folding.normalize(item.title).contains(normalizedQuery)))
          item,
    ]);
    _libraryCatalog = catalog;
    _libraryFavorites = favorites;
    _libraryFavoritesLen = favorites.length;
    _libraryFilterCache = libraryFilter;
    _libraryQueryCache = _libraryQuery;
    _libraryItemsCache = result;
    return result;
  }

  void selectTab(int value, {String? filter}) {
    diagnostics.record('app.tab', {'tab': value});
    final previousTab = tab;
    tab = value;
    if (filter != null) {
      _libraryFilter = filter;
      if (previousTab != 2) {
        _libraryQuery = '';
      }
    }
    _emit();
    if (value == 3 &&
        !browserVisible &&
        !busy &&
        (_portal != null || _portalHostActive)) {
      unawaited(syncAccount());
    }
    if (value == 2 &&
        libraryFilter == 'favorites' &&
        !accountSynced &&
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

  /// User-selected glass tier: `performance`, `standard` or `premium`.
  ///
  /// `main.dart` maps this onto the theme's glass quality tier; the strings
  /// stay stable because they are persisted under `baha.device.glass`.
  Future<void> setGlassStyle(String value) async {
    if (!const ['performance', 'standard', 'premium'].contains(value)) {
      return;
    }
    glassStyle = value;
    _emit();
    await _savePreference('baha.device.glass', value);
  }

  Future<void> setSkipOpLongPress(bool value) async {
    if (_skipOpLongPress == value) return;
    _skipOpLongPress = value;
    _emit();
    await _savePreference('baha.device.skipOpLongPress', value ? '1' : '0');
  }

  Future<void> setSkipAgeConfirmation(bool value) async {
    if (_skipAgeConfirmation == value) return;
    _skipAgeConfirmation = value;
    final write = _savePreference(
      'baha.device.skipAgeConfirmation',
      value ? '1' : '0',
    );
    _emit();
    await write;
  }

  Future<void> _savePreference(String key, String value) =>
      _preferences.write(key, value);

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

  bool _rememberPosters(Iterable<Anime> series, {bool mergeCatalog = true}) {
    for (final item in series) {
      if (item.poster case final poster?) {
        _posterIndex.storeRecent(item.id, poster, limit: 1000);
      }
    }
    if (!mergeCatalog) return false;
    final merged = _mergePosters(catalog);
    if (identical(merged, catalog)) return false;
    catalog = merged;
    return true;
  }

  Catalog _mergePosters(Catalog source) {
    List<Anime>? items;
    for (final (index, item) in source.items.indexed) {
      final poster = _posterIndex[item.id];
      if (item.poster != null || poster == null) continue;
      (items ??= source.items.toList(growable: false))[index] = item.copyWith(
        poster: poster,
      );
    }
    if (items == null) return source;
    return Catalog(
      items: items,
      fetchedAt: source.fetchedAt,
      seasonalPopularIds: source.seasonalPopularIds,
      collections: source.collections,
    );
  }

  Future<void> _refreshPosters() async {
    if (_disposed ||
        !_applicationActive ||
        postersLoading ||
        catalog.items.every((e) => e.poster != null)) {
      return;
    }
    postersLoading = true;
    final generation = _posterGeneration;
    try {
      final recent = await searchService.recentSeries();
      if (_disposed || generation != _posterGeneration) return;
      if (_rememberPosters(recent)) {
        _emit();
        await _saveCatalogCache(catalog);
      }
      final pending = catalog.items
          .where(
            (e) => e.poster == null && !_posterLookupsAttempted.contains(e.id),
          )
          .toList();
      var next = 0;
      var rateLimited = false;
      final found = <Anime>[];
      Future<void> worker() async {
        while (!_disposed &&
            generation == _posterGeneration &&
            _applicationActive &&
            !rateLimited &&
            next < pending.length) {
          final item = pending[next++];
          try {
            final matches = await searchService.search(
              item.title,
              useAccount: false,
            );
            if (_disposed || generation != _posterGeneration) return;
            _posterLookupsAttempted.add(item.id);
            if (_posterLookupsAttempted.length > 500) {
              _posterLookupsAttempted.remove(_posterLookupsAttempted.first);
            }
            found.addAll(matches.where((match) => match.id == item.id));
          } on OfficialAppApiException catch (error) {
            if (error.code == 'http-429' || error.code == 'http-403') {
              rateLimited = true;
            }
          } catch (_) {
            // Keep existing public artwork on a temporary metadata failure.
          }
        }
      }

      await Future.wait([for (var i = 0; i < 2; i++) worker()]);
      if (_disposed || generation != _posterGeneration) return;
      if (_rememberPosters(found)) {
        _emit();
        await _saveCatalogCache(catalog);
      }
    } catch (_) {
      // An unavailable artwork endpoint must not discard the catalog cache.
    } finally {
      postersLoading = false;
    }
  }

  Future<void> _saveCatalogCache(Catalog snapshot) {
    final pending = _catalogCacheWrite.then((_) => cache.save(snapshot));
    _catalogCacheWrite = pending.catchError((Object _) {});
    return pending;
  }

  void updateNavigation(Uri? uri, {required bool canGoBack}) {
    if (usesNativeHttpPlayback) return;
    browserUri = uri;
    browserCanGoBack = canGoBack;
    _emit();
  }

  Map<String, Object?> _metadataFailureData(Object error) =>
      error is OfficialAppApiException
      ? {
          'code': error.code,
          if (error.socketErrorCode != null)
            'socketErrorCode': error.socketErrorCode,
          if (error.officialCode != null) 'officialCode': error.officialCode,
        }
      : {'type': error.runtimeType.toString()};

  Future<void> refreshCatalog({bool force = true}) async {
    if (_disposed || browserVisible || (!force && catalogLoading)) return;
    final fetchedAt = DateTime.tryParse(catalog.fetchedAt);
    if (!force && fetchedAt != null) {
      final age = DateTime.now().difference(fetchedAt);
      if (!age.isNegative && age < const Duration(minutes: 2)) return;
    }
    if (!_applicationActive) {
      _catalogNeedsRetryOnResume = true;
      return;
    }
    _catalogNeedsRetryOnResume = false;
    final generation = ++_catalogGeneration;
    catalogLoading = true;
    catalogFailed = false;
    catalogError = null;
    _emit();
    Catalog? updated;
    try {
      final fetched = await metadataApi.fetchCatalog();
      if (_disposed || generation != _catalogGeneration) return;
      _rememberPosters([
        ...catalog.items,
        for (final collection in fetched.collections) ...collection.items,
      ], mergeCatalog: false);
      updated = _mergePosters(fetched);
      catalog = updated;
      catalogSource = 'live';
      diagnostics.record('catalog.completed', {'count': updated.items.length});
    } catch (error) {
      if (_disposed || generation != _catalogGeneration) return;
      if (!_applicationActive) {
        _catalogNeedsRetryOnResume = true;
        diagnostics.record('catalog.deferred', _metadataFailureData(error));
        return;
      }
      catalogFailed = true;
      catalogError = error is OfficialAppApiException ? error.code : 'network';
      diagnostics.record('catalog.failed', _metadataFailureData(error));
    } finally {
      if (!_disposed && generation == _catalogGeneration) {
        catalogLoading = false;
        _emit();
        if (updated != null) {
          unawaited(
            _saveCatalogCache(updated).catchError((Object _) {
              if (!_disposed && generation == _catalogGeneration) {
                notice = t('storageError');
              }
            }),
          );
          unawaited(_refreshPosters());
        }
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
    _detailCancel?.complete();
    final cancel = _detailCancel = Completer<void>();
    final generation = ++_detailGeneration;
    selectedAnime = anime;
    detail = null;
    detailLoading = true;
    detailFailed = false;
    _pendingAnime = anime;
    final videoId = anime.latestVideoId;
    if (videoId != null) {
      // Retire an older HTML detail request, while leaving playback/account
      // operations intact during an independent metadata read.
      if (operation.intent == BrowserIntent.detail) {
        _begin(BrowserIntent.idle);
        busy = false;
        _pendingUri = null;
      }
      _emit();
      try {
        final fetched = await _fetchDetail(anime.id, videoId, cancel.future);
        if (_disposed || generation != _detailGeneration) return;
        detail = fetched;
        _cacheDetail(anime.id, fetched);
        diagnostics.record('detail.completed');
        unawaited(
          _attachDetailRating(anime.id, fetched, cancel.future, () {
            return !_disposed && generation == _detailGeneration;
          }, (rated) => detail = rated),
        );
      } catch (error) {
        if (_disposed || generation != _detailGeneration) return;
        detailFailed = true;
        diagnostics.record('detail.failed', _metadataFailureData(error));
      } finally {
        if (!_disposed && generation == _detailGeneration) {
          detailLoading = false;
          _emit();
        }
      }
      return;
    }
    _emit();
    if (browserUri != null && OfficialSite.trustedOrigin(browserUri!)) {
      _begin(BrowserIntent.detail);
      _armDeadline();
      await _runScript('detail', {'%ANIME_ID%': anime.id});
    } else {
      await _load(OfficialSite.home, BrowserIntent.detail, visible: false);
    }
  }

  Future<AnimeDetail> _fetchDetail(
    String animeId,
    String videoId,
    Future<void> cancel,
  ) {
    final cached = _detailCache.readRecent(animeId);
    if (cached != null &&
        DateTime.now().isBefore(cached.$2) &&
        cached.$1.episodes.any((episode) => episode.id == videoId)) {
      return Future.value(cached.$1);
    }
    if (cached != null && !DateTime.now().isBefore(cached.$2)) {
      _detailCache.remove(animeId);
    }
    return metadataApi.fetchDetail(
      animeId: animeId,
      videoId: videoId,
      includeRating: false,
      cancel: cancel,
    );
  }

  void _cacheDetail(String animeId, AnimeDetail result) {
    if (identical(_detailCache[animeId]?.$1, result)) return;
    _detailCache.storeRecent(animeId, (
      result,
      DateTime.now().add(const Duration(minutes: 5)),
    ), limit: 25);
  }

  Future<void> _attachDetailRating(
    String animeId,
    AnimeDetail result,
    Future<void> cancel,
    bool Function() current,
    void Function(AnimeDetail) save,
  ) async {
    final fanId = result.fanId;
    if (fanId == null || result.rating != null) return;
    try {
      final rating = await metadataApi.fetchRating(fanId, cancel: cancel);
      if (rating == null || !current()) return;
      final rated = OfficialAppMetadata.attachRating(result, rating);
      if (identical(_detailCache[animeId]?.$1, result)) {
        _cacheDetail(animeId, rated);
      }
      save(rated);
      if (identical(detail, result)) detail = rated;
      if (identical(playerDetail, result)) playerDetail = rated;
      _emit();
    } catch (_) {
      // The existing detail remains available if reviews fail.
    }
  }

  Future<void> _loadPlayerDetail(
    Anime anime,
    String videoId,
    String document,
  ) async {
    final cancel = _playerDetailCancel = Completer<void>();
    bool current() =>
        !_disposed &&
        operation.id == document &&
        identical(_playerDetailCancel, cancel);
    try {
      final result = await _fetchDetail(anime.id, videoId, cancel.future);
      if (!current()) return;
      playerDetail = result;
      _cacheDetail(anime.id, result);
      _emit();
      await _attachDetailRating(
        anime.id,
        result,
        cancel.future,
        current,
        (rated) => playerDetail = rated,
      );
    } catch (_) {
      // A metadata failure cannot change the authorization session.
    }
  }

  Future<void> search() async {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) return;
    final input = query;
    final generation = ++_searchGeneration;
    _searchCancel?.complete();
    final cancel = _searchCancel = Completer<void>();
    searching = true;
    searchFailed = false;
    _emit();
    try {
      if (_disposed || generation != _searchGeneration) return;
      final service = searchService;
      final items = service is OfficialAnimeSearch
          ? await service.search(input, cancel: cancel.future)
          : await service.search(input);
      if (_disposed || generation != _searchGeneration || query != input) {
        return;
      }
      searchResults = items;
      diagnostics.record('search.completed', {'count': items.length});
      searchedQuery = input;
      _rememberPosters(items);
    } catch (error) {
      if (_disposed || generation != _searchGeneration || query != input) {
        return;
      }
      searchResults = [];
      searchFailed = true;
      diagnostics.record('search.failed', _metadataFailureData(error));
    }
    if (generation == _searchGeneration) {
      _searchCancel = null;
      searching = false;
      _emit();
    }
  }

  Future<void> connectAccount() async {
    if (_disposed || loggingOut) return;
    final clearingOwner = hasAccount;
    _invalidateAccountRequests();
    _resetNotifications();
    accountProfile = null;
    favorites = [];
    history = [];
    accountSynced = false;
    if (clearingOwner) _resetAccountComments();
    unawaited(_saveAccountSnapshot(null));
    final pending = OfficialCookieRotation.pending;
    if (pending != null) {
      final generation = _accountGeneration;
      final document = operation.id;
      await pending;
      if (_disposed ||
          generation != _accountGeneration ||
          document != operation.id) {
        return;
      }
    }
    browserTitle = t('officialAccount');
    await _load(
      OfficialSite.home.resolve('mygather.php'),
      BrowserIntent.account,
      visible: true,
    );
  }

  Future<bool> logoutAccount() async {
    if (loggingOut || _disposed) return false;
    _loggingOut = true;
    _favoriteAfterLogin = null;
    _invalidateAccountRequests();
    _resetNotifications();
    accountProfile = null;
    favorites = [];
    history = [];
    accountSynced = false;
    accountNeedsRefresh = false;
    _resetAccountComments();
    _detailGeneration++;
    _searchGeneration++;
    _posterGeneration++;
    _detailCancel?.complete();
    _detailCancel = null;
    _playerDetailCancel?.complete();
    _playerDetailCancel = null;
    _searchCancel?.complete();
    _searchCancel = null;
    _searchDebounce?.cancel();
    _detailCache.clear();
    if (searchService case final OfficialAnimeSearch search) search.reset();
    folding.clearCache();
    _posterIndex.clear();
    _posterLookupsAttempted.clear();
    searching = false;
    detailLoading = false;
    browserVisible = false;
    browserCanGoBack = false;
    browserUri = null;
    browserError = false;
    verificationRequired = false;
    busy = false;
    notice = null;
    _pendingUri = null;
    _accountSyncDocument = null;
    playerFullscreen = false;
    playerLocked = false;
    _lastGoodPlayback = null;
    final playbackSession = nativeHttpPlayback;
    nativeHttpPlayback = null;
    playbackSession?.dispose();
    playback.value = const PlaybackState();
    _begin(BrowserIntent.idle);
    _emit();
    try {
      await Future.wait([
        accountApi.logout(),
        _writeAccountData(storage.clearAccountData, strict: true),
        if (playbackSession != null) playbackSession.released,
        ?_playbackRelease,
      ]);
      return true;
    } catch (_) {
      return false;
    } finally {
      _loggingOut = false;
      _emit();
    }
  }

  Future<void> toggleFavorite(Anime anime) async {
    if (loggingOut || _disposed) return;
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
          error.code == 'verification'
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
    if (loggingOut || _disposed) return;
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
    _playerDetailCancel?.complete();
    _playerDetailCancel = null;
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
      skipAgeConfirmation: skipAgeConfirmation,
      checkpoint: checkpoint,
      diagnostics: diagnostics,
      api: nativeHttpApiFactory?.call(),
      cookieLoader: OfficialHttpClient.loadPlaybackCookies,
      onState: (state) => updateNativePlayback(document, state),
    );
    final session = nativeHttpPlayback!;
    _emit();
    final closing = _closeNativePlayback(previous);
    unawaited(
      session.prepare(
        applicationActive: _applicationActive,
        nativeBackendAvailable: nativePlaybackBackend != null,
        waitBeforeInstall: _playbackRelease,
      ),
    );
    if (playerDetail == null && videoId.isNotEmpty) {
      unawaited(_loadPlayerDetail(anime, videoId, document));
    }
    await closing;
    if (_disposed || operation.id != document) {
      session.dispose();
      return;
    }
  }

  Future<void>? _closeNativePlayback(NativeHttpPlayback? session) {
    if (session == null) return null;
    final prior = _playbackRelease;
    final closing = session.close();
    final release = prior == null
        ? closing
        : Future.wait([prior, closing]).then<void>((_) {});
    _playbackRelease = release;
    void clear() {
      if (identical(_playbackRelease, release)) _playbackRelease = null;
    }

    unawaited(
      release.then<void>((_) => clear(), onError: (Object _) => clear()),
    );
    return closing;
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
    _playerDetailCancel?.complete();
    _playerDetailCancel = null;
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
    await _closeNativePlayback(http);
    await _releasePlayback(expected: closing, releaseSystemMedia: http != null);
    if (_disposed || operation.id != closing) return;
    playingAnime = null;
    playerDetail = null;
    playingVideoId = null;
    _emit();
    if (refreshAccount) {
      await syncAccount();
    } else if (verificationRequired || catalog.items.isEmpty) {
      await refreshCatalog();
    }
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

  void _checkAccountGeneration(int generation) {
    if (_disposed || loggingOut || generation != _accountGeneration) {
      throw const CommunityException('stale');
    }
  }

  Future<AccountProfile?> _fetchFreshProfile(int generation) async {
    final profile = await accountApi.fetchProfileModel(
      checkCurrent: () => _checkAccountGeneration(generation),
    );
    _checkAccountGeneration(generation);
    return profile;
  }

  bool _sameAccountOwner(AccountProfile? profile) =>
      profile != null &&
      profile.id.toLowerCase() == accountProfile?.id.toLowerCase();

  Future<bool> refreshAccountProfile({bool force = false}) async {
    if (_disposed ||
        !_applicationActive ||
        loggingOut ||
        _profileRefreshing ||
        operation.intent == BrowserIntent.account) {
      return false;
    }
    final checkedAt = _profileCheckedAt;
    if (!force && accountProfile != null && checkedAt != null) {
      final age = DateTime.now().millisecondsSinceEpoch - checkedAt;
      if (age >= 0 && age < const Duration(days: 1).inMilliseconds) return true;
    }
    _profileRefreshing = true;
    final generation = _accountGeneration;
    final revision = _accountSnapshotRevision;
    final identityRevision = _accountIdentityRevision;
    _emit();
    try {
      var profile = await _fetchFreshProfile(generation);
      final confirmGuest = profile == null && hasAccount;
      bool canApply() =>
          (revision == _accountSnapshotRevision &&
              identityRevision == _accountIdentityRevision) ||
          (!confirmGuest && _sameAccountOwner(profile));
      if (!canApply()) return false;
      if (confirmGuest) {
        profile = await _fetchFreshProfile(generation);
        if (!canApply()) return false;
      }
      final avatar = profile?.avatar;
      final sameOwner = _sameAccountOwner(profile);
      if (avatar != null) {
        if (force ||
            (sameOwner &&
                accountProfile?.avatar != null &&
                accountProfile!.avatar != avatar)) {
          try {
            final manager = CachedNetworkImageProvider.defaultCacheManager;
            if (force) {
              await manager.downloadFile(
                avatar,
                authHeaders: const {'Cache-Control': 'no-cache'},
              );
            } else {
              await manager.getSingleFile(avatar);
            }
          } catch (_) {
            if (sameOwner) rethrow;
          }
        }
        final evict = avatarEvictor;
        if (evict == null) {
          await CachedNetworkImageProvider(avatar).evict();
        } else {
          await evict(avatar);
        }
      }
      _checkAccountGeneration(generation);
      if (!canApply()) return false;
      await _saveFreshProfile(profile);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (!_disposed && generation == _accountGeneration) {
        _profileRefreshing = false;
        _emit();
      }
    }
  }

  Future<void> _saveFreshProfile(AccountProfile? profile) {
    _applyAccountProfile(profile, fresh: true);
    if (profile == null) {
      favorites = [];
      history = [];
      accountSynced = false;
      accountNeedsRefresh = false;
    } else if (!accountSynced) {
      accountNeedsRefresh = true;
    }
    _profileCheckedAt = profile == null
        ? null
        : DateTime.now().millisecondsSinceEpoch;
    accountPortraitVersion++;
    return _saveAccountSnapshot(
      profile == null
          ? null
          : {
              'profile': profile.toJson(),
              'favorites': [for (final anime in favorites) anime.toJson()],
              'history': [for (final entry in history) entry.toJson()],
            },
    );
  }

  Future<void> syncAccount({String? expectedOwner}) async {
    if (_disposed || loggingOut || accountLoading) return;
    final generation = _accountGeneration;
    final revision = _accountSnapshotRevision;
    var identityRevision = _accountIdentityRevision;
    bool canApply(AccountProfile? profile) =>
        revision == _accountSnapshotRevision &&
        (identityRevision == _accountIdentityRevision ||
            _sameAccountOwner(profile));
    accountLoading = true;
    _emit();
    try {
      final snapshot = await accountApi.fetchAccountSnapshot(
        expectedOwner: expectedOwner,
        onAuthenticated: (profile) {
          _checkAccountGeneration(generation);
          if (!canApply(profile)) throw const CommunityException('stale');
          _applyAccountProfile(profile);
          identityRevision = _accountIdentityRevision;
          accountNeedsRefresh = true;
          _emit();
        },
        checkCurrent: () => _checkAccountGeneration(generation),
      );
      _checkAccountGeneration(generation);
      if (snapshot == null && expectedOwner != null) {
        throw const CommunityException('login');
      }
      final profile = snapshot?.profile;
      if (!canApply(profile)) return;
      if (snapshot == null && hasAccount) {
        final confirmed = await _fetchFreshProfile(generation);
        _checkAccountGeneration(generation);
        if (!canApply(null)) return;
        if (confirmed != null) {
          accountNeedsRefresh = true;
          await _saveFreshProfile(confirmed);
          return;
        }
      }
      _applyAccountProfile(profile);
      favorites = snapshot?.favorites ?? [];
      history = snapshot?.history ?? [];
      accountSynced = snapshot != null;
      accountNeedsRefresh = false;
      if (notice == t('accountSyncError')) notice = null;
      await _saveAccountSnapshot(
        snapshot == null
            ? null
            : {...snapshot.toJson(), 'profile': accountProfile?.toJson()},
      );
    } catch (error) {
      if (!_disposed &&
          generation == _accountGeneration &&
          revision == _accountSnapshotRevision &&
          identityRevision == _accountIdentityRevision) {
        accountNeedsRefresh = true;
        notice = t(
          error is CommunityException && error.code == 'verification'
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

  void _applyAccountProfile(AccountProfile? profile, {bool fresh = false}) {
    _accountIdentityRevision++;
    final previous = accountProfile;
    final ownerChanged =
        previous?.id.toLowerCase() != profile?.id.toLowerCase() ||
        (profile == null && accountSynced);
    if (ownerChanged) {
      _profileCheckedAt = null;
      _resetNotifications();
      favorites = [];
      history = [];
      accountSynced = false;
      unawaited(_saveAccountSnapshot(null));
    } else if (!fresh &&
        _profileCheckedAt != null &&
        previous != null &&
        profile != null) {
      // The Anime menu can still contain stale login-cookie display data.
      profile = previous;
    } else if (!fresh && previous != null && profile != null) {
      profile = AccountProfile(
        id: profile.id,
        displayName: profile.displayName == profile.id
            ? previous.displayName
            : profile.displayName,
        avatar: profile.avatar ?? previous.avatar,
      );
    }
    accountProfile = profile;
    if (ownerChanged) _resetAccountComments();
  }

  void _invalidateAccountRequests() {
    _accountGeneration++;
    _profileRefreshing = false;
    _profileCheckedAt = null;
    accountLoading = false;
    accountApi.invalidate();
  }

  void navigationStarted() {
    if (usesNativeHttpPlayback) return;
    if (operation.intent == BrowserIntent.account &&
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
    if (body['type'] == 'account-authenticated') {
      _invalidateAccountRequests();
      final profile = AccountProfile.fromJson(body['profile'] as Json);
      final ownerChanged =
          accountProfile?.id.toLowerCase() != profile.id.toLowerCase();
      accountProfile = profile;
      if (ownerChanged) {
        _resetNotifications();
        favorites = [];
        history = [];
        accountSynced = false;
        _resetAccountComments();
        unawaited(_saveAccountSnapshot(null));
      }
      accountNeedsRefresh = true;
      browserVisible = false;
      busy = false;
      _pendingUri = null;
      _begin(BrowserIntent.idle);
      _emit();
      await syncAccount(expectedOwner: profile.id);
      if (accountProfile?.id == profile.id) unawaited(refreshAccountProfile());
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
        _invalidateAccountRequests();
        accountProfile = null;
        favorites = [];
        history = [];
        accountSynced = false;
        accountNeedsRefresh = false;
        _resetAccountComments();
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
    final data = snapshot == null
        ? null
        : {
            ...snapshot,
            if (!accountSynced) 'collectionsSynced': false,
            if (_profileCheckedAt != null)
              'profileCheckedAt': _profileCheckedAt,
          };
    return _writeAccountData(() => AccountCache(storage).save(data));
  }

  Future<void> _writeAccountData(
    Future<void> Function() action, {
    bool strict = false,
  }) {
    final previous = _accountCacheWrite;
    final write = () async {
      if (previous != null) await previous;
      await action();
    }();
    // Serialize clearing after all display-data writes, including read markers.
    _accountCacheWrite = write.catchError((Object _) {});
    return strict ? write : _accountCacheWrite!;
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
    await _closeNativePlayback(http);
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
    final expected = operation.id;
    var source = scripts[name];
    final load = _scriptLoader;
    if (source == null && load != null) {
      try {
        source = await load(name);
      } catch (_) {
        if (operation.id == expected && !_disposed) navigationFailed();
        return;
      }
    }
    if (_disposed || operation.id != expected) return;
    if (source == null || _portal == null) {
      navigationFailed();
      return;
    }
    for (final entry in replacements.entries) {
      source = source!.replaceAll(entry.key, entry.value);
    }
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

  Object? _searchScope,
      _libraryScope,
      _detailScope,
      _notificationScope,
      _accountScope,
      _browserScope,
      _catalogScope;

  Object get _searchState =>
      (_query, searching, searchFailed, searchResults, searchedQuery);
  Object get _libraryState => (
    _libraryFilter,
    _libraryQuery,
    _libraryGeneration,
    _nextLibraryPage,
    _libraryCatalogLoading,
    _libraryCatalogHasMore,
    _libraryCatalogError,
  );
  Object get _detailState =>
      (selectedAnime, detail, detailLoading, detailFailed, playerDetail);
  Object get _notificationState =>
      (notifications, notificationsLoading, notificationsError, _readRevision);
  Object get _accountState => (
    accountProfile,
    accountLoading,
    _profileRefreshing,
    accountPortraitVersion,
    favorites,
    history,
    accountSynced,
    accountNeedsRefresh,
    _loggingOut,
  );
  Object get _browserState => (
    browserVisible,
    browserUri,
    browserCanGoBack,
    browserTitle,
    busy,
    browserError,
    favoriteLoginPending,
    playerFullscreen,
    playerLocked,
    operation.id,
    verificationRequired,
  );
  Object get _catalogState =>
      (catalog, catalogLoading, catalogFailed, catalogSource, catalogError);

  void _captureScopes() {
    _searchScope = _searchState;
    _libraryScope = _libraryState;
    _detailScope = _detailState;
    _notificationScope = _notificationState;
    _accountScope = _accountState;
    _browserScope = _browserState;
    _catalogScope = _catalogState;
  }

  void _emitSearch() {
    if (_disposed || _searchScope == _searchState) return;
    _searchScope = _searchState;
    searchNotifier.value++;
  }

  void _emitLibraryFilter() {
    if (_disposed || _libraryScope == _libraryState) return;
    _libraryScope = _libraryState;
    libraryFilterNotifier.value++;
  }

  void _emit() {
    if (_disposed) return;
    final scopes = [
      (_searchScope, _searchState, searchNotifier),
      (_libraryScope, _libraryState, libraryFilterNotifier),
      (_detailScope, _detailState, detailNotifier),
      (_notificationScope, _notificationState, notificationsNotifier),
      (_accountScope, _accountState, accountNotifier),
      (_browserScope, _browserState, browserNotifier),
      (_catalogScope, _catalogState, catalogNotifier),
    ];
    _captureScopes();
    for (final (before, after, notifier) in scopes) {
      if (before != after && !_disposed) notifier.value++;
    }
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
    _libraryGeneration++;
    _searchCancel?.complete();
    _detailCancel?.complete();
    _playerDetailCancel?.complete();
    _libraryCancel?.complete();
    _preferences.dispose();
    nativeHttpPlayback?.dispose();
    danmakuSender.dispose();
    accountApi.dispose();
    metadataApi.dispose();
    _deadline?.cancel();
    _searchDebounce?.cancel();
    _searchGeneration++;
    searchService.dispose();
    updates.dispose();
    playback.removeListener(_recordPlayback);
    playback.dispose();
    commentsVersion.dispose();
    noticeEvents.dispose();
    danmakuSettingsNotifier.dispose();
    searchNotifier.dispose();
    libraryFilterNotifier.dispose();
    detailNotifier.dispose();
    notificationsNotifier.dispose();
    accountNotifier.dispose();
    browserNotifier.dispose();
    catalogNotifier.dispose();
    super.dispose();
  }
}
