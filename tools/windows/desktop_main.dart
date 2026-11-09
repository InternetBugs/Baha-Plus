import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import 'main.dart' as application;

AppLifecycleListener? _exitListener;
const _exitChannel = MethodChannel('baha_plus/desktop_lifecycle');
const _webViewChannel = MethodChannel(
  'com.pichillilorenzo/flutter_inappwebview_manager',
);
Future<void>? _closing;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  VideoPlayerMediaKit.ensureInitialized(
    android: false,
    iOS: false,
    macOS: false,
    windows: true,
    linux: false,
  );
  _exitChannel.setMethodCallHandler((call) async {
    if (call.method != 'prepareExit') {
      throw MissingPluginException('Unknown desktop lifecycle method');
    }
    await _prepareDesktopExit();
  });
  _exitListener?.dispose();
  _exitListener = AppLifecycleListener(
    onExitRequested: () async {
      await _prepareDesktopExit();
      return AppExitResponse.exit;
    },
  );
  await application.main();
  debugPrint('[BAHA_DESKTOP] app-root-attached');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    debugPrint('[BAHA_DESKTOP] app-first-frame');
  });
}

Future<void> _prepareDesktopExit() => _closing ??= _releaseDesktopViews();

Future<void> _releaseDesktopViews() async {
  // WebView2 must release its child window and texture while the Flutter
  // engine and parent HWND still exist. The default runner otherwise destroys
  // the parent before plugin teardown begins.
  final elapsed = Stopwatch()..start();
  const budget = Duration(seconds: 12);
  debugPrint(
    '[BAHA_DESKTOP] exit-requested '
    'lifecycle=${WidgetsBinding.instance.lifecycleState?.name} '
    'framesEnabled=${WidgetsBinding.instance.framesEnabled}',
  );
  try {
    runApp(const SizedBox.shrink());
    // Warm-up frames also run when the window is minimized, when normal
    // scheduled frames can be suspended by the lifecycle state.
    WidgetsBinding.instance.scheduleWarmUpFrame();
    await WidgetsBinding.instance.endOfFrame.timeout(
      _remaining(elapsed, budget),
    );
    debugPrint('[BAHA_DESKTOP] widgets-unmounted');
    await shutdownNativeDesktopViews(timeout: _remaining(elapsed, budget));
  } catch (_) {
    _closing = null;
    rethrow;
  }
}

/// Called only after all desktop platform-view widgets have been unmounted.
Future<void> shutdownNativeDesktopViews({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final shutdown = Stopwatch()..start();
  while (await _webViewChannel
          .invokeMethod<bool>('shutdownForDesktopExit')
          .timeout(_remaining(shutdown, timeout)) !=
      true) {
    _remaining(shutdown, timeout);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  debugPrint('[BAHA_DESKTOP] native-disposed');
}

Duration _remaining(Stopwatch elapsed, Duration budget) {
  final remaining = budget - elapsed.elapsed;
  if (remaining <= Duration.zero) {
    throw TimeoutException('Windows desktop shutdown did not complete', budget);
  }
  return remaining;
}
