import 'dart:io';
import 'package:platform_proxy/platform_proxy.dart';
import 'package:platform_proxy/proxy_httpclient.dart';

/// Lets Dart image clients use the same device proxy settings as the WebView.
/// The delegated client retains Dart's normal TLS certificate validation.
class SystemHttpOverrides extends HttpOverrides {
  SystemHttpOverrides({PlatformProxy? platformProxy})
    : _platformProxy = platformProxy ?? PlatformProxy();

  final PlatformProxy _platformProxy;

  @override
  HttpClient createHttpClient(SecurityContext? context) => ProxyAwareHttpClient(
    client: super.createHttpClient(context),
    platformProxy: _platformProxy,
  );
}
