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
import '../core/playback_state.dart';
import '../data/app_store.dart';
import '../data/ios_hls_cache.dart';
import '../data/native_playback.dart';
import '../data/windows_official_bridge.dart';
import 'player_page.dart';
import 'native_video_surface.dart';

/// One native WebView owns an active official login/player/account operation.
/// Only typed public/account projections cross the origin-restricted bridge.
/// AppRoot releases this view when the operation and its teardown finish.
class OfficialBrowser extends StatefulWidget {
  const OfficialBrowser({required this.store, super.key});
  final AppStore store;
  @override
  State<OfficialBrowser> createState() => _OfficialBrowserState();
}

class _OfficialBrowserState extends State<OfficialBrowser>
    with WidgetsBindingObserver
    implements OfficialPortal {
  InAppWebViewController? _controller;
  // Keep the plugin delegate and its controller together across route and
  // layout rebuilds, as well as retaining the native view with the GlobalKey.
  InAppWebView? _webView;
  final _progress = ValueNotifier<int>(0);
  GlobalKey _webViewKey = GlobalKey(debugLabel: 'official-video-session');
  bool _webViewNeedsRecreation = false;
  Completer<void>? _recreatedWebViewReady;
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
  NativePlayback? _nativePlayback;
  Future<void> _nativeRelease = Future.value();
  String? _preparingNative, _nativeAttempted;
  String? _nativeFailureDocument;
  bool _syncingNative = false;
  bool _readingNativeDanmaku = false;
  int _lifecycleRevision = 0;
  Timer? _nativeClockTimer;
  DateTime? _lastNativeSync;
  List<NativeDanmaku> _nativeDanmaku = const [];
  Timer? _danmakuTimer;
  static const _diagnostics = bool.fromEnvironment('BAHA_DIAGNOSTICS');
  AppStore get store => widget.store;
  bool _isCurrentController(InAppWebViewController controller) =>
      identical(controller.platform, _controller?.platform);
  bool get _shouldKeepAndroidMediaAlive =>
      defaultTargetPlatform == TargetPlatform.android && store.showsPlayer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_cacheSessionChanged);
    store.diagnostics.addListener(_diagnosticCaptureChanged);
    _diagnosticCaptureChanged();
  }

  void _diagnosticCaptureChanged() {
    _healthTimer?.cancel();
    _healthTimer = null;
    if (_diagnostics || store.diagnostics.enabled) {
      _healthTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_samplePlaybackHealth()),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _lifecycleRevision++;
      unawaited(_hlsCache.setApplicationActive(false));
      unawaited(_nativePlayback?.setApplicationActive(false));
    } else if (state == AppLifecycleState.resumed) {
      _lifecycleRevision++;
      unawaited(_hlsCache.setApplicationActive(true));
      _lastNativeSync = null;
      unawaited(_nativePlayback?.setApplicationActive(true));
      unawaited(_syncNativeClock());
    }
    if (_diagnostics) {
      debugPrint(
        '[BAHA_NATIVE] lifecycle=${state.name} '
        'active=${_nativePlayback?.active == true}',
      );
    }
  }

  @override
  void didUpdateWidget(covariant OfficialBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != store) {
      oldWidget.store.removeListener(_cacheSessionChanged);
      oldWidget.store.diagnostics.removeListener(_diagnosticCaptureChanged);
      store.addListener(_cacheSessionChanged);
      store.diagnostics.addListener(_diagnosticCaptureChanged);
      _diagnosticCaptureChanged();
      _cacheSessionChanged();
    }
  }

  void _cacheSessionChanged() {
    final native = _nativePlayback;
    if (native != null &&
        (!store.showsPlayer ||
            !store.browserVisible ||
            native.document != store.operation.id)) {
      _nativePlayback = null;
      _nativeDanmaku = const [];
      _danmakuTimer?.cancel();
      _nativeClockTimer?.cancel();
      _lastNativeSync = null;
      native.dispose();
      _nativeRelease = Future.wait([_nativeRelease, native.released])
          .then<void>((_) {})
          .catchError((Object _) {
            debugPrint('[BAHA_NATIVE] player release unavailable');
          });
    } else if (native != null && !store.applicationActive) {
      unawaited(native.setApplicationActive(false));
    }
    if (_nativeFailureDocument != store.operation.id) {
      _nativeFailureDocument = null;
    }
    final document = _hlsCache.document;
    unawaited(_hlsCache.setApplicationActive(store.applicationActive));
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
        AppStore.nativePlaybackBackend != null ||
        !mounted ||
        !store.showsPlayer ||
        !store.browserVisible ||
        !store.applicationActive ||
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
    final lifecycle = _lifecycleRevision;
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
      if (!store.applicationActive || lifecycle != _lifecycleRevision) return;
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
      if (!store.applicationActive || lifecycle != _lifecycleRevision) return;
      if (result?.value == null && result?.error == null) return;
      _cacheAttemptedDocument = document;
      if (result?.value != true || result?.error != null) {
        await _hlsCache.stop(document);
      } else {
        _cacheInUse = true;
        await _hlsCache.update(document, store.playback.value.position);
      }
    } catch (_) {
      if (!store.applicationActive || lifecycle != _lifecycleRevision) return;
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
    useOnRenderProcessGone: true,
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
    final document = store.operation.id;
    await _nativeRelease.timeout(const Duration(seconds: 10));
    if (!mounted || store.operation.id != document) return;
    await _recreateWebViewIfNeeded();
    if (!mounted || store.operation.id != document) return;
    await _syncInitialQualityScript();
    if (!mounted || store.operation.id != document) return;
    await _configureMode(uri);
    if (!mounted || store.operation.id != document) return;
    await _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri(uri.toString())),
    );
  }

  @override
  Future<void> reload() async {
    if (_webViewNeedsRecreation) {
      await load(
        store.showsPlayer && store.playingVideoId != null
            ? OfficialSite.video(store.playingVideoId!)
            : store.browserUri ?? OfficialSite.home,
      );
      return;
    }
    final document = store.operation.id;
    await _nativeRelease.timeout(const Duration(seconds: 10));
    if (!mounted || store.operation.id != document) return;
    await _syncInitialQualityScript();
    if (!mounted || store.operation.id != document) return;
    await _controller?.reload();
  }

  Future<void> _recreateWebViewIfNeeded() async {
    if (_webViewNeedsRecreation) {
      _webViewNeedsRecreation = false;
      _controller = null;
      _queuedInitialQuality = null;
      _initialQualityWrite = Future.value();
      _recreatedWebViewReady = Completer<void>();
      setState(() {
        _webView = null;
        _webViewKey = GlobalKey(debugLabel: 'official-video-session');
      });
    }
    await _recreatedWebViewReady?.future.timeout(const Duration(seconds: 15));
  }

  @override
  Future<void> goBack() async {
    await _syncInitialQualityScript();
    await _controller?.goBack();
  }

  @override
  Future<dynamic> evaluate(String script) async {
    // On exit this completes before AppStore deactivates AVAudioSession.
    // Navigation can replace the operation before its next store notification.
    _cacheSessionChanged();
    await _nativeRelease;
    return _controller?.evaluateJavascript(source: script);
  }

  @override
  Future<bool> playerCommand(
    String document,
    String action,
    double? value,
  ) async {
    final native = _nativePlayback;
    if (native?.active == true && native!.document == document) {
      final accepted = await native.command(action, value);
      if (accepted) unawaited(_syncNativeClock());
      return accepted;
    }
    if (AppStore.nativePlaybackBackend != null &&
        (store.usesNativePlayback ||
            store.playback.value.phase == PlaybackPhase.content ||
            _preparingNative == document ||
            _nativeAttempted == document)) {
      return false;
    }
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
      final native = _nativePlayback;
      if (native?.active == true) {
        final state = native!.state;
        store.diagnostics.record('player.health', {
          'backend': AppStore.nativePlaybackBackend,
          'phase': state.phase.name,
          ...native.clock,
          'bufferAhead': (state.buffered - state.position).clamp(
            0,
            state.duration,
          ),
          'authorized': native.authorizationAvailable,
        });
        debugPrint(
          '[BAHA_HEALTH] ${jsonEncode({'backend': AppStore.nativePlaybackBackend, 'phase': state.phase.name, ...native.clock, 'bufferAhead': (state.buffered - state.position).clamp(0, state.duration), 'authorizationAvailable': native.authorizationAvailable})}',
        );
        return;
      }
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
        // The bridge's diagnostics projection contains metrics only; never
        // sample page HTML, JavaScript console messages or network payloads.
        final body = jsonDecode(result.value as String);
        if (body is Map<String, dynamic>) {
          store.diagnostics.record('player.health', {
            for (final entry in body.entries)
              if (entry.value is num || entry.value is bool)
                entry.key: entry.value,
            if (const [
              'loading',
              'content',
              'advertisement',
              'age',
              'verification',
              'official',
              'error',
            ].contains(body['phase']))
              'phase': body['phase'],
            if (const [
              'vhs',
              'native-hls',
              'android-exoplayer',
              'ios-avplayer',
              'windows-mpv',
            ].contains(body['backend']))
              'backend': body['backend'],
          });
        }
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
      if (_diagnostics) {
        await InAppWebViewController.setWebContentsDebuggingEnabled(true);
      }
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
    if (defaultTargetPlatform == TargetPlatform.windows &&
        AppStore.windowsNativePlaybackEnabled) {
      await attachWindowsOfficialBridge(
        controller,
        (raw) => _receiveOfficialMessage(controller, raw, OfficialSite.home),
      );
    } else {
      await controller.addWebMessageListener(
        WebMessageListener(
          jsObjectName: 'baha',
          allowedOriginRules: {'https://ani.gamer.com.tw'},
          onPostMessage:
              (message, sourceOrigin, isMainFrame, replyProxy) async {
                final raw = message?.data;
                if (raw is! String || sourceOrigin == null || !isMainFrame) {
                  return;
                }
                final origin = Uri.tryParse(sourceOrigin.toString());
                if (origin != null) {
                  await _receiveOfficialMessage(controller, raw, origin);
                }
              },
        ),
      );
    }
    if (!mounted || !_isCurrentController(controller)) return;
    final recreated = _recreatedWebViewReady;
    if (recreated != null) {
      _recreatedWebViewReady = null;
      recreated.complete();
    } else {
      await store.attach(this);
    }
  }

  void _playerProcessTerminated(
    InAppWebViewController controller, {
    bool recreate = false,
  }) {
    if (!mounted ||
        !_isCurrentController(controller) ||
        _terminatedGeneration == _documentGeneration) {
      return;
    }
    _terminatedGeneration = _documentGeneration;
    _publicDocumentReady = false;
    _webViewNeedsRecreation |= recreate;
    store.diagnostics.record('browser.process-terminated', {
      'recreate': recreate,
    });
    debugPrint('[BAHA_HEALTH] web-content-process-terminated');
    final native = _nativePlayback;
    // Capture the timeline before pausing or blocking changes playback intent.
    // Reloading also disposes the native decoder before creating another one.
    unawaited(store.playerProcessTerminated());
    unawaited(native?.block(recoverable: true));
  }

  Future<void> _receiveOfficialMessage(
    InAppWebViewController controller,
    String raw,
    Uri origin,
  ) async {
    if (!mounted || !_isCurrentController(controller)) return;
    final requestId = store.operation.id;
    final nativeUrl = await controller.getUrl();
    if (!mounted ||
        !_isCurrentController(controller) ||
        nativeUrl == null ||
        store.operation.id != requestId) {
      return;
    }
    final source = Uri.tryParse(nativeUrl.toString());
    if (source == null) return;
    final body = store.operation.accept(
      raw,
      origin: origin,
      source: source,
      isMainFrame: true,
    );
    await store.receive(raw, origin: origin, source: source, isMainFrame: true);
    if (body != null) {
      unawaited(_syncHlsCache(body, requestId));
      unawaited(_prepareNativePlayback(body, requestId));
    }
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
      Offstage(
        // The official session stays mounted for authorization and heartbeats.
        // Once native playback covers it, exclude its texture from composition.
        offstage: _nativePlayback?.active == true,
        child: _webView ??= InAppWebView(
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
          onWebContentProcessDidTerminate: _playerProcessTerminated,
          onRenderProcessGone: (controller, detail) =>
              _playerProcessTerminated(controller, recreate: true),
          onLoadStart: (controller, url) async {
            if (!mounted || !_isCurrentController(controller)) return;
            _documentGeneration++;
            _publicDocumentReady = false;
            _progress.value = 1;
            store.navigationStarted();
            await _updateNavigation();
          },
          onPageCommitVisible: (controller, url) async {
            if (!mounted || !_isCurrentController(controller)) return;
            final uri = url == null ? null : Uri.tryParse(url.toString());
            _publicDocumentReady =
                uri != null && OfficialSite.trustedOrigin(uri);
            await store.preparePlayerSurface(uri);
          },
          onLoadStop: (controller, url) async {
            if (!mounted || !_isCurrentController(controller)) return;
            final uri = url == null ? null : Uri.tryParse(url.toString());
            _publicDocumentReady =
                uri != null && OfficialSite.trustedOrigin(uri);
            _progress.value = 100;
            await _updateNavigation();
            await store.navigationFinished(
              url == null ? null : Uri.tryParse(url.toString()),
            );
          },
          onUpdateVisitedHistory: (controller, url, isReload) =>
              _updateNavigation(),
          onProgressChanged: (controller, progress) =>
              _progress.value = progress,
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
            if (!_isCurrentController(controller) ||
                request.isForMainFrame != true ||
                error.description.contains('ERR_ABORTED')) {
              return;
            }
            store.diagnostics.record('browser.network-error', {
              'code': error.type.toNativeValue(),
            });
            if (store.showsPlayer) {
              unawaited(store.playerProcessTerminated());
            } else {
              store.navigationFailed();
            }
          },
          onReceivedHttpError: (controller, request, response) {
            if (request.isForMainFrame == true) {
              store.diagnostics.record('browser.http-error', {
                'status': response.statusCode,
              });
            }
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
      ),
      if (_nativePlayback?.active == true)
        NativeVideoSurface(
          key: ValueKey('native-video-${_nativePlayback!.document}'),
          playback: _nativePlayback!,
          danmaku: _nativeDanmaku,
          settings: store.danmakuSettings,
          errorLabel: store.t('playerPlaybackError'),
          retryLabel: store.t('retry'),
          onRetry: store.retryPlayback,
          suppressErrors:
              store.resumingPlayback || store.waitingToResumePlayback,
        ),
      if (_nativeFailureDocument == store.operation.id &&
          !store.resumingPlayback &&
          !store.waitingToResumePlayback)
        ColoredBox(
          color: Colors.black,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  store.t('playerPlaybackError'),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 20),
                GlassButton.custom(
                  shape: const LiquidRoundedRectangle(borderRadius: 22),
                  onTap: store.retryPlayback,
                  width: 116,
                  height: 44,
                  child: Text(store.t('retry')),
                ),
              ],
            ),
          ),
        ),
      if (store.browserError &&
          !store.resumingPlayback &&
          !store.waitingToResumePlayback)
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
                  onTap: store.retryPlayback,
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
    WidgetsBinding.instance.removeObserver(this);
    _healthTimer?.cancel();
    _danmakuTimer?.cancel();
    _nativePlayback?.dispose();
    _nativeClockTimer?.cancel();
    store.removeListener(_cacheSessionChanged);
    store.detach(this);
    store.diagnostics.removeListener(_diagnosticCaptureChanged);
    final document = _hlsCache.document;
    if (document != null) unawaited(_hlsCache.stop(document));
    _progress.dispose();
    super.dispose();
  }

  Future<void> _prepareNativePlayback(Json body, String document) async {
    final backend = AppStore.nativePlaybackBackend;
    if (backend == null ||
        !mounted ||
        !store.showsPlayer ||
        !store.browserVisible ||
        !store.applicationActive ||
        store.operation.id != document ||
        body['type'] != 'player-state' ||
        body['phase'] != 'content' ||
        (body['duration'] as num? ?? 0) <= 0 ||
        _preparingNative == document ||
        _nativeAttempted == document ||
        _nativePlayback?.active == true) {
      return;
    }
    _preparingNative = document;
    final lifecycle = _lifecycleRevision;
    NativePlayback? candidate;
    bool live() =>
        mounted &&
        store.operation.id == document &&
        store.showsPlayer &&
        store.browserVisible;
    try {
      final prepared = await _controller
          ?.callAsyncJavaScript(
            arguments: {'ticket': document},
            functionBody: '''
if (window.__bahaDocumentNonce !== ticket) return null;
const source = await window.__bahaPlayerBridge?.prepareNative();
return JSON.stringify(source ? {...source, userAgent: navigator.userAgent} : null);
''',
          )
          .timeout(const Duration(seconds: 15));
      if (!live()) return;
      if (prepared?.value is! String || prepared?.error != null) {
        throw StateError('Native source preparation unavailable');
      }
      final raw = jsonDecode(prepared!.value as String);
      if (raw == null) {
        throw StateError('Native source preparation unavailable');
      }
      final source = NativePlaybackSource.fromJson(raw as Json);
      // Desktop content mode may change WKWebView's agent. Use the agent of
      // the actual authorized document, rather than a separate default view.
      final userAgent = raw['userAgent'];
      if (userAgent is! String ||
          userAgent.isEmpty ||
          userAgent.length > 4096 ||
          userAgent.contains(RegExp(r'[\r\n]'))) {
        throw const FormatException('Invalid native media user agent');
      }
      candidate = NativePlayback(
        diagnostics: store.diagnostics,
        document: document,
        source: source,
        userAgent: userAgent,
        onState: (value) {
          if (!live()) return;
          store.updateNativePlayback(
            document,
            value,
            recoverable:
                (store.resumingPlayback || store.waitingToResumePlayback)
                ? candidate?.retryable == true
                : candidate?.recoverable == true,
          );
        },
      );
      store.updateNativePlayback(
        document,
        const PlaybackState(phase: PlaybackPhase.loading),
      );
      await candidate
          .initialize(store.preferredQuality)
          .timeout(const Duration(seconds: 40));
      if (!live()) return;
      final committed = await _controller
          ?.callAsyncJavaScript(
            arguments: {'ticket': document},
            functionBody: '''
if (window.__bahaDocumentNonce !== ticket) return null;
return JSON.stringify(window.__bahaPlayerBridge?.commitNative() ?? null);
''',
          )
          .timeout(const Duration(seconds: 5));
      if (!live()) return;
      if (committed?.value is! String || committed?.error != null) {
        throw StateError('Native handoff unavailable');
      }
      final timeline = jsonDecode(committed!.value as String);
      if (timeline is! Json) throw StateError('Native handoff unavailable');
      _nativePlayback = candidate;
      _nativeAttempted = document;
      await candidate
          .activate(
            applicationActive: store.applicationActive,
            timeline: {
              ...timeline,
              'paused':
                  timeline['paused'] != false ||
                  lifecycle != _lifecycleRevision,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (!live()) return;
      setState(() {});
      debugPrint('[BAHA_NATIVE] $backend handoff complete');
      store.diagnostics.record('player.native-handoff', {'backend': backend});
      _nativeClockTimer?.cancel();
      _nativeClockTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_syncNativeClock()),
      );
      unawaited(_syncNativeClock());
      unawaited(_readNativeDanmaku());
      _danmakuTimer?.cancel();
      _danmakuTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_readNativeDanmaku()),
      );
    } catch (error) {
      if (live()) {
        _nativeAttempted = document;
        if (candidate != null && _nativePlayback == candidate) {
          await candidate.block(committed: true, recoverable: true);
          if (live()) {
            store.updateNativePlayback(
              document,
              candidate.state,
              recoverable: true,
            );
            setState(() {});
          }
        } else {
          store.updateNativePlayback(
            document,
            const PlaybackState(phase: PlaybackPhase.error),
            recoverable: true,
          );
          setState(() => _nativeFailureDocument = document);
          unawaited(
            _controller?.callAsyncJavaScript(
              arguments: {'ticket': document},
              functionBody: '''
if (window.__bahaDocumentNonce === ticket) window.__bahaPlayerBridge?.failNative();
''',
            ),
          );
        }
        debugPrint(
          '[BAHA_NATIVE] initialization unavailable: ${error.runtimeType} '
          'stage=${candidate?.failureStage ?? 'handoff'} '
          'code=${candidate?.failureCode ?? 'unavailable'}',
        );
        store.diagnostics.record('player.native-failed', {
          'type': error.runtimeType.toString(),
          'stage': candidate?.failureStage ?? 'handoff',
          'code': candidate?.failureCode ?? 'unavailable',
        });
      }
    } finally {
      if (_nativePlayback != candidate) candidate?.dispose();
      if (_preparingNative == document) _preparingNative = null;
    }
  }

  Future<void> _syncNativeClock() async {
    final native = _nativePlayback;
    if (!mounted ||
        native?.active != true ||
        _syncingNative ||
        !store.applicationActive) {
      return;
    }
    final now = DateTime.now();
    if (native!.state.paused &&
        native.authorizationAvailable &&
        _lastNativeSync != null &&
        now.difference(_lastNativeSync!) < const Duration(seconds: 5)) {
      return;
    }
    _lastNativeSync = now;
    _syncingNative = true;
    final lifecycle = _lifecycleRevision;
    try {
      final result = await _controller
          ?.callAsyncJavaScript(
            arguments: {'ticket': native.document, 'clock': native.clock},
            functionBody: '''
if (window.__bahaDocumentNonce !== ticket) return 'unavailable';
const bridge = window.__bahaPlayerBridge;
if (bridge?.nativeStatus() === 'denied') return 'denied';
return bridge?.syncNative(clock) === true ? 'ok' : 'unavailable';
''',
          )
          .timeout(const Duration(seconds: 5));
      if (_nativePlayback == native &&
          lifecycle == _lifecycleRevision &&
          store.applicationActive) {
        if (result?.error == null && result?.value == 'denied') {
          _nativeClockTimer?.cancel();
          await native.block();
        } else {
          await native.setAuthorizationAvailable(
            result?.error == null && result?.value == 'ok',
          );
        }
      }
    } catch (_) {
      if (_nativePlayback == native &&
          lifecycle == _lifecycleRevision &&
          store.applicationActive) {
        await native.setAuthorizationAvailable(false);
      }
    } finally {
      _syncingNative = false;
    }
  }

  Future<void> _readNativeDanmaku() async {
    final native = _nativePlayback;
    if (!mounted ||
        native?.active != true ||
        !store.applicationActive ||
        _readingNativeDanmaku) {
      return;
    }
    _readingNativeDanmaku = true;
    try {
      final result = await _controller
          ?.callAsyncJavaScript(
            arguments: {'ticket': native!.document},
            functionBody: '''
if (window.__bahaDocumentNonce !== ticket) return null;
return JSON.stringify(window.__bahaPlayerBridge?.nativeDanmaku() ?? []);
''',
          )
          .timeout(const Duration(seconds: 5));
      if (!mounted || _nativePlayback != native || result?.value is! String) {
        return;
      }
      final raw = jsonDecode(result!.value as String) as List;
      if (raw.isEmpty || raw.length > 20000) return;
      final items = raw
          .map((item) => NativeDanmaku.fromJson(item as Json))
          .toList();
      final merged = {for (final item in _nativeDanmaku) item.id: item};
      for (final item in items) {
        if (merged.length >= 20000 && !merged.containsKey(item.id)) break;
        merged[item.id] = item;
      }
      final sorted = merged.values.toList()
        ..sort((a, b) => a.time.compareTo(b.time));
      setState(() => _nativeDanmaku = sorted);
      await _controller?.callAsyncJavaScript(
        arguments: {
          'ticket': native!.document,
          'ids': items.map((item) => item.id).toList(),
        },
        functionBody: '''
return window.__bahaDocumentNonce === ticket &&
  window.__bahaPlayerBridge?.acknowledgeNativeDanmaku(ids) === true;
''',
      );
      debugPrint('[BAHA_NATIVE] native danmaku loaded: ${sorted.length}');
    } catch (_) {
      // A metadata refresh must never replace an already playing native video.
    } finally {
      _readingNativeDanmaku = false;
    }
  }
}
