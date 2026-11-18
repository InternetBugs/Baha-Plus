import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/browser_presentation.dart';

/// One request identity for the official site. The player page, account,
/// comment, danmaku and playback HTTP all present [value], derived from the
/// installed WebView, so cookies, device checks and Cloudflare clearance are
/// never created under one agent and replayed under another. Ordinary login
/// browsing keeps the WebView's own agent.
abstract final class OfficialUserAgent {
  /// Used before resolution finishes and on hosts without a WebView agent
  /// (the Windows debug build). It must stay a desktop Chromium string: the
  /// official player page and the native parsers expect a desktop document.
  static const fallback =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static String? _device;
  static String? _value;

  /// The WebView's own agent. Android WebView reports `wv` and `Mobile`
  /// markers, so playback and official requests use [value] instead.
  static String get device => _device ?? fallback;

  /// Exactly what this app's WebView presents: Android keeps the desktop
  /// presentation used for the player pages; iOS keeps its real Safari agent.
  /// Every official HTTP request and the native media backend send this.
  static String get value => _value ??=
      Platform.isAndroid ? desktopChromiumUserAgent(device) : device;

  /// Reads the installed engine once. Failure keeps [fallback] rather than
  /// letting a partial agent split the identity across requests. Hosts with
  /// no mobile WebView (the Windows debug build) never attempt it.
  static Future<void> resolve() async {
    if (_device != null) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final agent = await InAppWebViewController.getDefaultUserAgent().timeout(
        const Duration(seconds: 5),
      );
      if (agent.startsWith('Mozilla/5.0 ') && agent.length < 1024) {
        _device = agent;
        _value = null;
      }
    } catch (_) {
      // Missing plugin or host without a WebView: keep the fallback identity.
    }
  }
}
