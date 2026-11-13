import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/browser_presentation.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import '../data/windows_official_bridge.dart';

/// Hosts official login/logout, browsing and details without a video ID.
/// Playback and account data use native HTTP independently of this view.
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
  GlobalKey _webViewKey = GlobalKey(debugLabel: 'official-browser');
  bool _webViewNeedsRecreation = false;
  Completer<void>? _recreatedWebViewReady;
  bool _desktop = false;
  String? _nativeAgent;
  static const _diagnostics = bool.fromEnvironment('BAHA_DIAGNOSTICS');
  AppStore get store => widget.store;
  bool _isCurrentController(InAppWebViewController controller) =>
      identical(controller.platform, _controller?.platform);
  InAppWebViewSettings _settingsForMode(bool desktop) => InAppWebViewSettings(
    useHybridComposition: false,
    useOnRenderProcessGone: true,
    javaScriptEnabled: true,
    javaScriptCanOpenWindowsAutomatically: false,
    useShouldOverrideUrlLoading: true,
    mediaPlaybackRequiresUserGesture: true,
    allowsInlineMediaPlayback: true,
    allowsPictureInPictureMediaPlayback: false,
    allowBackgroundAudioPlaying: false,
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
    if (_desktop == desktop) return;
    await _controller?.setSettings(settings: _settingsForMode(desktop));
    _desktop = desktop;
  }

  @override
  Future<void> load(Uri uri) async {
    if (!OfficialSite.allowedNavigation(uri)) return;
    final document = store.operation.id;
    await _recreateWebViewIfNeeded();
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
      await load(store.browserUri ?? OfficialSite.home);
      return;
    }
    await _controller?.reload();
  }

  Future<void> _recreateWebViewIfNeeded() async {
    if (_webViewNeedsRecreation) {
      _webViewNeedsRecreation = false;
      _controller = null;
      _recreatedWebViewReady = Completer<void>();
      setState(() {
        _webView = null;
        _webViewKey = GlobalKey(debugLabel: 'official-browser');
      });
    }
    await _recreatedWebViewReady?.future.timeout(const Duration(seconds: 15));
  }

  @override
  Future<void> goBack() async {
    await _controller?.goBack();
  }

  @override
  Future<dynamic> evaluate(String script) async {
    return _controller?.evaluateJavascript(source: script);
  }

  Future<void> _updateNavigation() async {
    final controller = _controller;
    if (controller == null) return;
    final url = await controller.getUrl();
    final canGoBack = await controller.canGoBack();
    if (mounted && _isCurrentController(controller)) {
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
    if (defaultTargetPlatform == TargetPlatform.windows) {
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

  void _browserProcessTerminated(
    InAppWebViewController controller, {
    bool recreate = false,
  }) {
    if (!mounted || !_isCurrentController(controller)) return;
    _webViewNeedsRecreation |= recreate;
    store.diagnostics.record('browser.process-terminated', {
      'recreate': recreate,
    });
    store.navigationFailed();
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
    await store.receive(raw, origin: origin, source: source, isMainFrame: true);
  }

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).scaffoldBackgroundColor;
    final surface = _surface(background);
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
        onWebViewCreated: _created,
        onWebContentProcessDidTerminate: _browserProcessTerminated,
        onRenderProcessGone: (controller, detail) =>
            _browserProcessTerminated(controller, recreate: true),
        onLoadStart: (controller, url) async {
          if (!mounted || !_isCurrentController(controller)) return;
          _progress.value = 1;
          store.navigationStarted();
          await _updateNavigation();
        },
        onLoadStop: (controller, url) async {
          if (!mounted || !_isCurrentController(controller)) return;
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
          if (!_isCurrentController(controller) ||
              request.isForMainFrame != true ||
              error.description.contains('ERR_ABORTED')) {
            return;
          }
          store.diagnostics.record('browser.network-error', {
            'code': error.type.toNativeValue(),
          });
          store.navigationFailed();
        },
        onReceivedHttpError: (controller, request, response) {
          if (request.isForMainFrame == true) {
            store.diagnostics.record('browser.http-error', {
              'status': response.statusCode,
            });
          }
        },
        onPermissionRequest: (controller, request) async {
          return PermissionResponse(
            resources: [],
            action: PermissionResponseAction.DENY,
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
    store.detach(this);
    _progress.dispose();
    super.dispose();
  }
}
