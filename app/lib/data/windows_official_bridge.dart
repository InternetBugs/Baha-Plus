import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../core/models.dart';

/// WebView2's plugin forwards top-level WebMessageReceived events through
/// callHandler, but its WebMessageListener factory is not implemented.
/// The document script is restricted to the official top frame; native URL
/// and the existing request nonce/type/source checks still gate every message.
const windowsOfficialMessageHandler = 'bahaOfficialSession';

Future<void> attachWindowsOfficialBridge(
  InAppWebViewController controller,
  FutureOr<void> Function(String raw) receive,
) async {
  controller.addJavaScriptHandler(
    handlerName: windowsOfficialMessageHandler,
    callback: (arguments) async {
      if (arguments.length != 1 || arguments.single is! String) return null;
      final raw = arguments.single as String;
      if (raw.length >= 5000000) return null;
      final nativeUrl = await controller.getUrl();
      final source = Uri.tryParse(nativeUrl?.toString() ?? '');
      if (source == null ||
          source.userInfo.isNotEmpty ||
          !OfficialSite.trustedOrigin(source)) {
        return null;
      }
      await receive(raw);
      return null;
    },
  );
  await controller.addUserScript(
    userScript: UserScript(
      groupName: 'baha-windows-session',
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: true,
      allowedOriginRules: {'https://ani.gamer.com.tw'},
      source:
          '''
(function() {
  if (window !== window.top || location.origin !== 'https://ani.gamer.com.tw') return;
  Object.defineProperty(window, 'baha', {
    value: Object.freeze({
      postMessage: function(raw) {
        if (typeof raw !== 'string') return;
        return window.flutter_inappwebview.callHandler('$windowsOfficialMessageHandler', raw);
      }
    })
  });
})();
''',
    ),
  );
}
