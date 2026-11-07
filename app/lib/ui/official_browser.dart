import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/browser_presentation.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import '../data/official_search.dart';
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
  final _progress = ValueNotifier<int>(0);
  final _webViewKey = GlobalKey(debugLabel: 'official-video-session');
  bool _desktop = false;
  bool _publicDocumentReady = false;
  String? _nativeAgent;
  int _documentGeneration = 0;
  AppStore get store => widget.store;

  InAppWebViewSettings _settingsForMode(bool desktop) => InAppWebViewSettings(
    javaScriptEnabled: true,
    javaScriptCanOpenWindowsAutomatically: false,
    useShouldOverrideUrlLoading: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    allowsPictureInPictureMediaPlayback: false,
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
    isInspectable: kDebugMode || const bool.fromEnvironment('BAHA_DIAGNOSTICS'),
  );

  Future<void> _configureMode(Uri uri) async {
    final desktop = OfficialSite.desktopPlayer(uri);
    if (_desktop == desktop) return;
    // Settings constructors include defaults, so always preserve the complete
    // session/media configuration while changing presentation.
    await _controller?.setSettings(settings: _settingsForMode(desktop));
    _desktop = desktop;
  }

  @override
  Future<void> load(Uri uri) async {
    if (!OfficialSite.allowedNavigation(uri)) return;
    await _configureMode(uri);
    await _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri(uri.toString())),
    );
  }

  @override
  Future<void> reload() async => _controller?.reload();
  @override
  Future<void> goBack() async => _controller?.goBack();
  @override
  Future<dynamic> evaluate(String script) async =>
      _controller?.evaluateJavascript(source: script);

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
        .callAsyncJavaScript(functionBody: 'return await $body;')
        .timeout(const Duration(seconds: 30));
    final current = await controller.getUrl();
    if (!mounted ||
        generation != _documentGeneration ||
        (!communityReadActions.contains(action) &&
            store.operation.id != operation) ||
        current?.toString() != source) {
      throw const CommunityException('stale');
    }
    if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
      debugPrint(
        '[BAHA_DIAG] community action=$action '
        'error=${result?.error} valueType=${result?.value.runtimeType}',
      );
      if (result?.value is Map) {
        final response = result!.value as Map;
        debugPrint(
          '[BAHA_DIAG] community ok=${response['ok']} code=${response['code']}',
        );
      }
    }
    if (result?.error != null || result?.value is! Map) {
      throw const CommunityException('network');
    }
    final decoded = jsonDecode(jsonEncode(result!.value)) as Json;
    if (const bool.fromEnvironment('BAHA_DIAGNOSTICS') &&
        action == 'comments' &&
        decoded['ok'] == true) {
      debugPrint(
        '[BAHA_DIAG] comment number types total=${decoded['total'].runtimeType} '
        'nextPage=${decoded['nextPage'].runtimeType}',
      );
      try {
        final parsed = CommentPage.fromJson(decoded);
        debugPrint(
          '[BAHA_DIAG] comment parser ok rows=${parsed.comments.length}',
        );
      } catch (error) {
        debugPrint('[BAHA_DIAG] comment parser failed: $error');
      }
    }
    return decoded;
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
  return {data: {
    totalPage: body.data.totalPage,
    animeList: body.data.animeList.map(item => ({
      animeSn: item.animeSn, videoSn: item.videoSn, title: item.title,
      cover: item.cover, totalEpisode: item.totalEpisode, dateInfo: item.dateInfo
    }))
  }};
} finally { clearTimeout(timer); }
''',
        )
        .timeout(const Duration(seconds: 15));
    final source = await controller.getUrl();
    if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
      debugPrint(
        '[BAHA_DIAG] catalog path=${uri.path} '
        'error=${result?.error} valueType=${result?.value.runtimeType}',
      );
    }
    if (!mounted ||
        result?.error != null ||
        source == null ||
        !OfficialSite.trustedOrigin(Uri.parse(source.toString())) ||
        result?.value is! Map) {
      throw StateError('Official catalog request failed');
    }
    final decoded = jsonDecode(jsonEncode(result!.value)) as Json;
    if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
      try {
        final parsed = OfficialAnimeSearch.parseResponse(decoded);
        debugPrint('[BAHA_DIAG] catalog parser ok rows=${parsed.length}');
      } catch (error) {
        final rows = (decoded['data'] as Map?)?['animeList'] as List?;
        final first = rows?.firstOrNull as Map?;
        debugPrint(
          '[BAHA_DIAG] catalog parser failed: $error '
          'animeSnType=${first?['animeSn'].runtimeType} '
          'videoSnType=${first?['videoSn'].runtimeType}',
        );
      }
    }
    return decoded;
  }

  Future<void> _diagnoseMedia() async {
    if (!const bool.fromEnvironment('BAHA_DIAGNOSTICS')) return;
    final controller = _controller;
    if (controller == null) return;
    final uri = await controller.getUrl();
    if (uri == null || !OfficialSite.trustedOrigin(Uri.parse(uri.toString()))) {
      return;
    }
    final numbers = await controller.callAsyncJavaScript(
      functionBody: 'return {integer: 1, zero: 0, negative: -1};',
    );
    final values = numbers?.value;
    if (values is Map) {
      debugPrint(
        '[BAHA_DIAG] numeric bridge integer=${values['integer'].runtimeType} '
        'zero=${values['zero'].runtimeType} '
        'json=${jsonEncode(values)}',
      );
    }
    final src = await controller.evaluateJavascript(
      source:
          "document.querySelector('#video-container video')?.currentSrc || '';",
    );
    if (src is! String || src.isEmpty) return;
    try {
      final result = await const MethodChannel('baha.diagnostics')
          .invokeMethod<Object?>('inspectHls', {'url': src})
          .timeout(const Duration(seconds: 25));
      debugPrint('[BAHA_DIAG] native HLS ${jsonEncode(result)}');
    } catch (error) {
      debugPrint('[BAHA_DIAG] native HLS probe failed: ${error.runtimeType}');
    }
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
            await store.receive(
              raw,
              origin: origin,
              source: source,
              isMainFrame: isMainFrame,
            );
          }
        },
      ),
    );
    if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
      await controller.addWebMessageListener(
        WebMessageListener(
          jsObjectName: 'bahaDiagnostics',
          allowedOriginRules: {'https://ani.gamer.com.tw'},
          onPostMessage: (message, origin, mainFrame, reply) async {
            if (mainFrame &&
                message?.data == 'inspect' &&
                origin != null &&
                OfficialSite.trustedOrigin(Uri.parse(origin.toString()))) {
              await _diagnoseMedia();
            }
          },
        ),
      );
    }
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
      InAppWebView(
        key: _webViewKey,
        initialSettings: _settingsForMode(_desktop),
        onWebViewCreated: _created,
        onLoadStart: (controller, url) async {
          _documentGeneration++;
          _publicDocumentReady = false;
          _progress.value = 1;
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
          if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
            final uri = Uri.tryParse(request.url.toString());
            debugPrint(
              '[BAHA_DIAG] navigation error host=${uri?.host} '
              'path=${uri?.path} type=${error.type} description=${error.description}',
            );
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
    _progress.dispose();
    super.dispose();
  }
}
