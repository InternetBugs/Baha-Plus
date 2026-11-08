import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/browser_presentation.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import '../data/ios_hls_cache.dart';
import 'player_page.dart';

/// One persistent native WebView owns the official login and player session.
/// Only typed public/account projections cross the origin-restricted bridge.
class OfficialBrowser extends StatefulWidget {
  const OfficialBrowser({required this.store, super.key});
  final AppStore store;
  @override
  State<OfficialBrowser> createState() => _OfficialBrowserState();
}

class _OfficialBrowserState extends State<OfficialBrowser>
    implements OfficialPortal {
  InAppWebViewController? _controller;
  // Keep the plugin delegate and its controller together across route and
  // layout rebuilds, as well as retaining the native view with the GlobalKey.
  InAppWebView? _webView;
  final _progress = ValueNotifier<int>(0);
  final _webViewKey = GlobalKey(debugLabel: 'official-video-session');
  bool _desktop = false;
  bool _keepsAndroidMediaAlive = false;
  bool _publicDocumentReady = false;
  String? _nativeAgent;
  int _documentGeneration = 0;
  final _hlsCache = IOSHlsCache();
  String? _preparingCacheDocument;
  String? _cacheAttemptedDocument;
  bool _cacheInUse = false;
  int? _queuedInitialQuality;
  Future<void> _initialQualityWrite = Future<void>.value();
  Timer? _healthTimer;
  bool _readingHealth = false;
  int? _terminatedGeneration;
  static const _diagnostics = bool.fromEnvironment('BAHA_DIAGNOSTICS');
  AppStore get store => widget.store;
  bool get _shouldKeepAndroidMediaAlive =>
      defaultTargetPlatform == TargetPlatform.android && store.showsPlayer;

  @override
  void initState() {
    super.initState();
    store.addListener(_cacheSessionChanged);
    if (_diagnostics) {
      _healthTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_samplePlaybackHealth()),
      );
    }
  }

  @override
  void didUpdateWidget(covariant OfficialBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != store) {
      oldWidget.store.removeListener(_cacheSessionChanged);
      store.addListener(_cacheSessionChanged);
      _cacheSessionChanged();
    }
  }

  void _cacheSessionChanged() {
    final document = _hlsCache.document;
    if (document != null &&
        (!store.showsPlayer ||
            !store.browserVisible ||
            store.operation.id != document)) {
      unawaited(_hlsCache.stop(document));
      _cacheInUse = false;
    }
  }

  Future<void> _syncHlsCache(Json body, String document) async {
    if (!Platform.isIOS ||
        !mounted ||
        !store.showsPlayer ||
        !store.browserVisible ||
        store.operation.id != document ||
        body['type'] != 'player-state') {
      return;
    }
    if (_cacheInUse && body['cacheFailed'] == true) {
      _cacheInUse = false;
      await _hlsCache.stop(document);
      return;
    }
    if (body['phase'] != 'content') return;
    final source = body['mediaSource'];
    if (source is! String || !IOSHlsCache.validSource(source)) return;
    final sources = body['mediaSources'] ?? const [];
    if (sources is! List ||
        sources.length > 21 ||
        sources.any(
          (value) => value is! String || !IOSHlsCache.validSource(value),
        )) {
      return;
    }
    if (_hlsCache.document == document) {
      await _hlsCache.update(document, store.playback.value.position);
    }
    if (_preparingCacheDocument == document ||
        _cacheAttemptedDocument == document ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _preparingCacheDocument = document;
    try {
      final endpoint = await _hlsCache.prepare(
        document: document,
        videoId: store.playingVideoId!,
        source: source,
        additionalSources: sources
            .cast<String>()
            .where((value) => value != source)
            .toList(),
      );
      if (endpoint == null) {
        _cacheAttemptedDocument = document;
        return;
      }
      if (!mounted || store.operation.id != document || !store.showsPlayer) {
        await _hlsCache.stop(document);
        return;
      }
      final result = await _controller?.callAsyncJavaScript(
        arguments: {
          'ticket': document,
          'source': source,
          'base': endpoint.base,
        },
        functionBody: '''
return await window.__bahaPlayerBridge?.enableCache(ticket, source, base);
''',
      );
      if (!mounted || store.operation.id != document || !store.showsPlayer) {
        await _hlsCache.stop(document);
        return;
      }
      if (result?.value == null && result?.error == null) return;
      _cacheAttemptedDocument = document;
      if (result?.value != true || result?.error != null) {
        await _hlsCache.stop(document);
      } else {
        _cacheInUse = true;
        await _hlsCache.update(document, store.playback.value.position);
      }
    } catch (_) {
      _cacheAttemptedDocument = document;
      await _hlsCache.stop(document);
    } finally {
      if (_preparingCacheDocument == document) _preparingCacheDocument = null;
    }
  }

  InAppWebViewSettings _settingsForMode(bool desktop) => InAppWebViewSettings(
    // Keep Android video and Flutter controls in the texture compositor.
    // A scrolling hybrid view otherwise requires separate Android overlay
    // surfaces for the controls drawn above the official player.
    useHybridComposition: false,
    javaScriptEnabled: true,
    javaScriptCanOpenWindowsAutomatically: false,
    useShouldOverrideUrlLoading: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    allowsPictureInPictureMediaPlayback: false,
    // Preserve Android's media pipeline when the view is covered. The app
    // lifecycle pause guard still pauses video/audio on background or lock.
    allowBackgroundAudioPlaying: _shouldKeepAndroidMediaAlive,
    userAgent: Platform.isAndroid && _nativeAgent != null
        ? desktop
              ? desktopChromiumUserAgent(_nativeAgent!)
              : _nativeAgent
        : null,
    preferredContentMode: desktop
        ? UserPreferredContentMode.DESKTOP
        : UserPreferredContentMode.MOBILE,
    useWideViewPort: desktop,
    loadWithOverviewMode: desktop,
    cacheEnabled: true,
    incognito: false,
    sharedCookiesEnabled: true,
    thirdPartyCookiesEnabled: true,
    domStorageEnabled: true,
    supportZoom: true,
    builtInZoomControls: true,
    displayZoomControls: false,
    safeBrowsingEnabled: true,
    isInspectable: kDebugMode || _diagnostics,
  );

  Future<void> _configureMode(Uri uri) async {
    final desktop = OfficialSite.desktopPlayer(uri);
    final keepsMediaAlive = _shouldKeepAndroidMediaAlive;
    if (_desktop == desktop && _keepsAndroidMediaAlive == keepsMediaAlive) {
      return;
    }
    // Settings constructors include defaults, so always preserve the complete
    // session/media configuration while changing presentation.
    await _controller?.setSettings(settings: _settingsForMode(desktop));
    _desktop = desktop;
    _keepsAndroidMediaAlive = keepsMediaAlive;
  }

  @override
  Future<void> load(Uri uri) async {
    if (!OfficialSite.allowedNavigation(uri)) return;
    await _syncInitialQualityScript();
    await _configureMode(uri);
    await _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri(uri.toString())),
    );
  }

  @override
  Future<void> reload() async {
    await _syncInitialQualityScript();
    await _controller?.reload();
  }

  @override
  Future<void> goBack() async {
    await _syncInitialQualityScript();
    await _controller?.goBack();
  }

  @override
  Future<dynamic> evaluate(String script) async =>
      _controller?.evaluateJavascript(source: script);

  @override
  Future<bool> playerCommand(
    String document,
    String action,
    double? value,
  ) async {
    if (action == 'quality') await _syncInitialQualityScript();
    final result = await _controller?.callAsyncJavaScript(
      arguments: {'ticket': document, 'action': action, 'value': value},
      functionBody: '''
if (action === 'quality') window.__bahaPreferredQuality = value;
return await window.__bahaPlayerBridge?.command(ticket, action, value) === true;
''',
    );
    return mounted &&
        store.operation.id == document &&
        result?.error == null &&
        result?.value == true;
  }

  UserScript _initialQualityUserScript() => UserScript(
    groupName: 'baha-initial-quality',
    source: store.initialQualityScript,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: true,
  );

  Future<void> _syncInitialQualityScript() {
    final controller = _controller;
    final quality = store.preferredQuality;
    if (controller == null || _queuedInitialQuality == quality) {
      return _initialQualityWrite;
    }
    _queuedInitialQuality = quality;
    final previous = _initialQualityWrite;
    final script = _initialQualityUserScript();
    return _initialQualityWrite = () async {
      try {
        await previous;
      } catch (_) {
        /* Retry a failed registration. */
      }
      if (!mounted || _controller != controller) return;
      try {
        await controller.removeUserScriptsByGroupName(
          groupName: 'baha-initial-quality',
        );
        await controller.addUserScript(userScript: script);
      } catch (_) {
        if (_queuedInitialQuality == quality) _queuedInitialQuality = null;
        debugPrint('[BAHA_HEALTH] initial-quality registration unavailable');
      }
    }();
  }

  Future<void> _samplePlaybackHealth() async {
    if (_readingHealth ||
        !mounted ||
        !store.showsPlayer ||
        !store.browserVisible ||
        _controller == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden) {
      return;
    }
    _readingHealth = true;
    try {
      final result = await _controller!
          .callAsyncJavaScript(
            functionBody:
                'return JSON.stringify(window.__bahaPlayerBridge?.diagnostics() ?? null);',
          )
          .timeout(const Duration(seconds: 5));
      if (mounted &&
          result?.error == null &&
          result?.value is String &&
          result!.value != 'null') {
        debugPrint('[BAHA_HEALTH] ${result.value}');
      }
    } catch (_) {
      debugPrint('[BAHA_HEALTH] snapshot unavailable');
    } finally {
      _readingHealth = false;
    }
  }

  @override
  Future<Json> community(String action, Json arguments) async {
    final script = store.scripts['community'];
    if (script == null) throw const CommunityException('unavailable');
    InAppWebViewController? controller;
    String? source;
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (mounted && DateTime.now().isBefore(deadline)) {
      final candidate = _controller;
      final url = await candidate?.getUrl();
      if (_publicDocumentReady &&
          candidate != null &&
          url != null &&
          OfficialSite.trustedOrigin(Uri.parse(url.toString()))) {
        controller = candidate;
        source = url.toString();
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted || controller == null || source == null) {
      throw const CommunityException('unavailable');
    }
    final generation = _documentGeneration;
    final operation = store.operation.id;
    final body = script.replaceAll(
      '__BAHA_COMMUNITY_REQUEST__',
      jsonEncode({'action': action, 'args': arguments}),
    );
    final result = await controller
        // WebKit bridges numeric object properties as doubles. Serialize in
        // JavaScript so integer IDs and counts keep their type in Dart.
        .callAsyncJavaScript(
          functionBody: 'return JSON.stringify(await $body);',
        )
        .timeout(const Duration(seconds: 30));
    final current = await controller.getUrl();
    if (!mounted ||
        generation != _documentGeneration ||
        (!communityReadActions.contains(action) &&
            store.operation.id != operation) ||
        current?.toString() != source) {
      throw const CommunityException('stale');
    }
    if (result?.error != null || result?.value is! String) {
      throw const CommunityException('network');
    }
    return jsonDecode(result!.value as String) as Json;
  }

  @override
  Future<Json> fetchPublicCatalog(Uri uri, {required bool useAccount}) async {
    if (uri.scheme != 'https' ||
        uri.host != 'api.gamer.com.tw' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        !const [
          '/anime/v1/search.php',
          '/anime/v1/anime_list.php',
        ].contains(uri.path)) {
      throw const FormatException('Invalid public catalog endpoint');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    InAppWebViewController? controller;
    while (mounted && DateTime.now().isBefore(deadline)) {
      controller = _controller;
      final source = await controller?.getUrl();
      if (_publicDocumentReady &&
          source != null &&
          OfficialSite.trustedOrigin(Uri.parse(source.toString()))) {
        break;
      }
      controller = null;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted || controller == null) {
      throw StateError('Official catalog connection is not ready');
    }
    final result = await controller
        .callAsyncJavaScript(
          arguments: {'url': uri.toString(), 'useAccount': useAccount},
          functionBody: '''
const endpoint = new URL(url);
if (location.origin !== 'https://ani.gamer.com.tw' ||
    endpoint.origin !== 'https://api.gamer.com.tw' ||
    !['/anime/v1/search.php', '/anime/v1/anime_list.php'].includes(endpoint.pathname)) {
  throw Error('Invalid public catalog request');
}
const abort = new AbortController();
const timer = setTimeout(() => abort.abort(), 12000);
try {
  const response = await fetch(endpoint.href, {
    credentials: useAccount ? 'include' : 'omit',
    headers: {Accept: 'application/json'},
    signal: abort.signal
  });
  if (!response.ok || new URL(response.url).origin !== endpoint.origin ||
      new URL(response.url).pathname !== endpoint.pathname) throw Error('Catalog unavailable');
  const text = await response.text();
  if (new TextEncoder().encode(text).byteLength > 5000000) throw Error('Catalog too large');
  const body = JSON.parse(text);
  if (!Array.isArray(body?.data?.animeList)) throw Error('Invalid catalog response');
  return JSON.stringify({data: {
    totalPage: body.data.totalPage,
    animeList: body.data.animeList.map(item => ({
      animeSn: item.animeSn, videoSn: item.videoSn, title: item.title,
      cover: item.cover, totalEpisode: item.totalEpisode, dateInfo: item.dateInfo
    }))
  }});
} finally { clearTimeout(timer); }
''',
        )
        .timeout(const Duration(seconds: 15));
    final source = await controller.getUrl();
    if (!mounted ||
        result?.error != null ||
        source == null ||
        !OfficialSite.trustedOrigin(Uri.parse(source.toString())) ||
        result?.value is! String) {
      throw StateError('Official catalog request failed');
    }
    return jsonDecode(result!.value as String) as Json;
  }

  Future<void> _updateNavigation() async {
    final controller = _controller;
    if (controller == null) return;
    final url = await controller.getUrl();
    final canGoBack = await controller.canGoBack();
    if (mounted) {
      store.updateNavigation(
        url == null ? null : Uri.tryParse(url.toString()),
        canGoBack: canGoBack,
      );
    }
  }

  Future<void> _created(InAppWebViewController controller) async {
    _controller = controller;
    if (Platform.isAndroid) {
      _nativeAgent = await InAppWebViewController.getDefaultUserAgent();
    }
    final supported =
        !Platform.isAndroid ||
        await WebViewFeature.isFeatureSupported(
          WebViewFeature.WEB_MESSAGE_LISTENER,
        );
    if (!supported) {
      store.notice = store.t('webViewUpdateRequired');
      store.navigationFailed();
      return;
    }
    await controller.addWebMessageListener(
      WebMessageListener(
        jsObjectName: 'baha',
        allowedOriginRules: {'https://ani.gamer.com.tw'},
        onPostMessage: (message, sourceOrigin, isMainFrame, replyProxy) async {
          final raw = message?.data;
          if (raw is! String || sourceOrigin == null || !isMainFrame) return;
          final requestId = store.operation.id;
          final nativeUrl = await controller.getUrl();
          if (!mounted ||
              nativeUrl == null ||
              store.operation.id != requestId) {
            return;
          }
          final origin = Uri.tryParse(sourceOrigin.toString());
          final source = Uri.tryParse(nativeUrl.toString());
          if (origin != null && source != null) {
            final body = store.operation.accept(
              raw,
              origin: origin,
              source: source,
              isMainFrame: isMainFrame,
            );
            await store.receive(
              raw,
              origin: origin,
              source: source,
              isMainFrame: isMainFrame,
            );
            if (body != null) unawaited(_syncHlsCache(body, requestId));
          }
        },
      ),
    );
    await store.attach(this);
  }

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).scaffoldBackgroundColor;
    final surface = _surface(background);
    if (store.showsPlayer) {
      return PlayerPage(
        key: const ValueKey('app-playback-page'),
        store: store,
        video: surface,
      );
    }
    return GlassScaffold(
      backgroundColor: background,
      extendBody: false,
      edgeFade: false,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: Text(
          store.browserTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        leading: GlassIconButton(
          key: const ValueKey('browser-close'),
          semanticLabel: store.t('close'),
          icon: const Icon(CupertinoIcons.xmark),
          onPressed: store.closeBrowser,
        ),
        actions: [
          if (store.browserCanGoBack)
            GlassIconButton(
              semanticLabel: store.t('back'),
              icon: const Icon(CupertinoIcons.chevron_back),
              onPressed: store.goBack,
            ),
          GlassIconButton(
            semanticLabel: store.t('refresh'),
            icon: const Icon(CupertinoIcons.arrow_clockwise),
            onPressed: store.reloadBrowser,
          ),
          if (store.canRetryFavorite)
            GlassIconButton(
              semanticLabel: store.t('retryFavorite'),
              icon: const Icon(CupertinoIcons.bookmark),
              onPressed: store.retryFavorite,
            ),
        ],
      ),
      body: Column(
        children: [
          ValueListenableBuilder(
            valueListenable: _progress,
            builder: (context, value, child) => value < 100 && value > 0
                ? LinearProgressIndicator(value: value / 100, minHeight: 2)
                : const SizedBox(height: 2),
          ),
          if (store.notice != null && store.browserVisible)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                store.notice!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(child: surface),
        ],
      ),
    );
  }

  Widget _surface(Color background) => Stack(
    fit: StackFit.expand,
    children: [
      _webView ??= InAppWebView(
        key: _webViewKey,
        initialSettings: _settingsForMode(_desktop),
        initialUserScripts: UnmodifiableListView([
          _initialQualityUserScript(),
          if (Platform.isIOS)
            UserScript(
              source: store.scripts['media-compat']!,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: true,
            ),
        ]),
        onWebViewCreated: _created,
        onWebContentProcessDidTerminate: (controller) {
          if (!mounted || _terminatedGeneration == _documentGeneration) return;
          _terminatedGeneration = _documentGeneration;
          _publicDocumentReady = false;
          debugPrint('[BAHA_HEALTH] web-content-process-terminated');
          unawaited(store.playerProcessTerminated());
        },
        onLoadStart: (controller, url) async {
          _documentGeneration++;
          _publicDocumentReady = false;
          _progress.value = 1;
          store.navigationStarted();
          await _updateNavigation();
        },
        onPageCommitVisible: (controller, url) async {
          final uri = url == null ? null : Uri.tryParse(url.toString());
          _publicDocumentReady = uri != null && OfficialSite.trustedOrigin(uri);
          await store.preparePlayerSurface(uri);
        },
        onLoadStop: (controller, url) async {
          final uri = url == null ? null : Uri.tryParse(url.toString());
          _publicDocumentReady = uri != null && OfficialSite.trustedOrigin(uri);
          _progress.value = 100;
          await _updateNavigation();
          await store.navigationFinished(
            url == null ? null : Uri.tryParse(url.toString()),
          );
        },
        onUpdateVisitedHistory: (controller, url, isReload) =>
            _updateNavigation(),
        onProgressChanged: (controller, progress) => _progress.value = progress,
        shouldOverrideUrlLoading: (controller, action) async {
          if (action.isForMainFrame != true) {
            return NavigationActionPolicy.ALLOW;
          }
          final raw = action.request.url;
          if (raw == null || raw.toString() == 'about:blank') {
            return NavigationActionPolicy.ALLOW;
          }
          final uri = Uri.tryParse(raw.toString());
          if (uri == null || !OfficialSite.allowedNavigation(uri)) {
            return NavigationActionPolicy.CANCEL;
          }
          if (OfficialSite.desktopPlayer(uri) != _desktop &&
              (action.request.method ?? 'GET') == 'GET') {
            // Apply the new mode after cancelling the old request.
            // Changing an agent mid-navigation can reload the wrong URL.
            unawaited(
              Future<void>(() async {
                await controller.stopLoading();
                await load(uri);
              }),
            );
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame != true ||
              error.description.contains('ERR_ABORTED')) {
            return;
          }
          store.navigationFailed();
        },
        onPermissionRequest: (controller, request) async {
          final origin = Uri.tryParse(request.origin.toString());
          final resources = request.resources
              .where(
                (resource) =>
                    resource == PermissionResourceType.PROTECTED_MEDIA_ID &&
                    origin != null &&
                    OfficialSite.trustedOrigin(origin) &&
                    store.browserVisible &&
                    store.browserIsPlayer,
              )
              .toList();
          return PermissionResponse(
            resources: resources,
            action: resources.isEmpty
                ? PermissionResponseAction.DENY
                : PermissionResponseAction.GRANT,
          );
        },
      ),
      if (store.browserError)
        ColoredBox(
          color: background,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(CupertinoIcons.wifi_exclamationmark, size: 40),
                const SizedBox(height: 16),
                Text(store.t('playerError')),
                const SizedBox(height: 20),
                GlassButton.custom(
                  shape: const LiquidRoundedRectangle(borderRadius: 22),
                  onTap: store.reloadBrowser,
                  width: 116,
                  height: 44,
                  child: Text(store.t('retry')),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  @override
  void dispose() {
    _healthTimer?.cancel();
    store.removeListener(_cacheSessionChanged);
    final document = _hlsCache.document;
    if (document != null) unawaited(_hlsCache.stop(document));
    _progress.dispose();
    super.dispose();
  }
}
