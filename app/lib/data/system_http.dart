import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:platform_proxy/platform_proxy.dart';
import 'package:platform_proxy/proxy.dart';

/// Lets Dart HTTP clients use the same device proxy settings as the WebView.
/// The delegated client retains Dart's normal TLS certificate validation.
class SystemHttpOverrides extends HttpOverrides {
  SystemHttpOverrides({
    PlatformProxy? platformProxy,
    this.proxyCacheTtl = const Duration(seconds: 20),
  }) : _platformProxy = platformProxy ?? PlatformProxy(),
       _proxyCache = platformProxy == null ? _sharedCache : _ProxyCache();

  static final _sharedCache = _ProxyCache();
  static int _generation = 0;
  final PlatformProxy _platformProxy;
  final _ProxyCache _proxyCache;
  final Duration proxyCacheTtl;

  static void clearProxyCache() {
    _generation++;
    _sharedCache.refresh();
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      SystemProxyHttpClient._(
        client: super.createHttpClient(context),
        platformProxy: _platformProxy,
        proxyCacheTtl: proxyCacheTtl,
        cache: _proxyCache,
      );
}

class _ProxyCache {
  final entries = <String, ({String pac, DateTime expiresAt})>{};
  final inFlight = <String, Future<void>>{};
  int generation = SystemHttpOverrides._generation;

  void refresh() {
    if (generation == SystemHttpOverrides._generation) return;
    generation = SystemHttpOverrides._generation;
    entries.clear();
    inFlight.clear();
  }
}

/// Refreshes OS proxy resolution on a short TTL and evicts cached entries on
/// open failures so VPN/proxy or network transitions do not leave long-lived
/// Dart HTTP clients pinned to stale routes.
class SystemProxyHttpClient implements HttpClient {
  SystemProxyHttpClient({
    required HttpClient client,
    required PlatformProxy platformProxy,
    Duration proxyCacheTtl = const Duration(seconds: 20),
    DateTime Function()? now,
  }) : this._(
         client: client,
         platformProxy: platformProxy,
         proxyCacheTtl: proxyCacheTtl,
         cache: _ProxyCache(),
         now: now,
       );

  SystemProxyHttpClient._({
    required HttpClient client,
    required PlatformProxy platformProxy,
    required Duration proxyCacheTtl,
    required _ProxyCache cache,
    DateTime Function()? now,
  }) : _delegate = client,
       _platformProxy = platformProxy,
       _proxyCacheTtl = proxyCacheTtl,
       _proxyCache = cache,
       _now = now ?? DateTime.now {
    _delegate.findProxy = _findProxy;
  }

  final HttpClient _delegate;
  final PlatformProxy _platformProxy;
  final Duration _proxyCacheTtl;
  final DateTime Function() _now;
  final _ProxyCache _proxyCache;
  static final _invalidHost = RegExp(r'[\s;]');
  static final _invalidCredential = RegExp(r'[\s;@]');

  static String _cacheKey(Uri url) {
    final scheme = url.scheme.toLowerCase();
    final port = url.hasPort
        ? url.port
        : scheme == 'https'
        ? 443
        : 80;
    return '$scheme://${url.host.toLowerCase()}:$port';
  }

  static Uri _uriFor(String host, int port, String path) => Uri(
    scheme: port == 443 ? 'https' : 'http',
    host: host,
    port: port,
    path: path,
  );

  @visibleForTesting
  static String formatPac(Iterable<Proxy> proxies) {
    final parts = <String>[];
    for (final proxy in proxies) {
      final type = proxy.type.trim().toLowerCase();
      if (type == 'http' || type == 'https') {
        final host = proxy.host.trim();
        final port = int.tryParse(proxy.port.trim());
        if (host.isEmpty ||
            port == null ||
            port <= 0 ||
            port > 65535 ||
            host.contains(_invalidHost)) {
          continue;
        }
        final formattedHost = host.contains(':') && !host.startsWith('[')
            ? '[$host]'
            : host;
        final user = proxy.user.trim();
        final password = proxy.password.trim();
        final entry =
            user.isNotEmpty &&
                password.isNotEmpty &&
                !user.contains(_invalidCredential) &&
                !password.contains(_invalidCredential)
            ? 'PROXY $user:$password@$formattedHost:$port'
            : 'PROXY $formattedHost:$port';
        if (!parts.contains(entry)) parts.add(entry);
      } else if (type == 'none' || type == 'direct') {
        if (!parts.contains('DIRECT')) parts.add('DIRECT');
      }
    }
    return parts.join('; ');
  }

  String _findProxy(Uri url) {
    _proxyCache.refresh();
    final pac = _proxyCache.entries[_cacheKey(url)]?.pac;
    if (pac == null || pac.isEmpty) {
      return HttpClient.findProxyFromEnvironment(url);
    }
    return pac;
  }

  Future<void> _resolveProxies(Uri url) async {
    final key = _cacheKey(url);
    _proxyCache.refresh();
    final generation = _proxyCache.generation;
    final entries = _proxyCache.entries;
    final inFlight = _proxyCache.inFlight;
    final now = _now();
    entries.removeWhere((_, entry) => !now.isBefore(entry.expiresAt));
    final cached = entries.remove(key);
    if (cached != null) {
      entries[key] = cached;
      return;
    }
    final pending = inFlight[key];
    if (pending != null) {
      await pending;
      return;
    }
    final lookup = () async {
      try {
        final proxies = await _platformProxy
            .getPlatformProxies(url: url.toString())
            .timeout(const Duration(seconds: 2));
        final pac = formatPac(proxies);
        if (generation == SystemHttpOverrides._generation) {
          entries[key] = (pac: pac, expiresAt: _now().add(_proxyCacheTtl));
          if (entries.length > 128) entries.remove(entries.keys.first);
        }
      } catch (_) {
        // Platform proxy errors (e.g. malformed plugin JSON or unavailable
        // channel) must not block HTTP requests; fall back to direct/env routing.
      } finally {
        if (generation == SystemHttpOverrides._generation) inFlight.remove(key);
      }
    }();
    inFlight[key] = lookup;
    await lookup;
  }

  Future<HttpClientRequest> _withProxy(
    Uri url,
    Future<HttpClientRequest> Function() action,
  ) async {
    await _resolveProxies(url);
    final key = _cacheKey(url);
    final entry = _proxyCache.entries[key];
    try {
      return await action();
    } catch (_) {
      if (identical(_proxyCache.entries[key], entry)) {
        _proxyCache.entries.remove(key);
      }
      rethrow;
    }
  }

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _delegate.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _delegate.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) {
    _delegate.close(force: force);
  }

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _withProxy(
        _uriFor(host, port, path),
        () => _delegate.delete(host, port, path),
      );

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _withProxy(url, () => _delegate.deleteUrl(url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _withProxy(
        _uriFor(host, port, path),
        () => _delegate.get(host, port, path),
      );

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _withProxy(url, () => _delegate.getUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _withProxy(
        _uriFor(host, port, path),
        () => _delegate.head(host, port, path),
      );

  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _withProxy(url, () => _delegate.headUrl(url));

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _withProxy(
    _uriFor(host, port, path),
    () => _delegate.open(method, host, port, path),
  );

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _withProxy(url, () => _delegate.openUrl(method, url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _withProxy(
        _uriFor(host, port, path),
        () => _delegate.patch(host, port, path),
      );

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _withProxy(url, () => _delegate.patchUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _withProxy(
        _uriFor(host, port, path),
        () => _delegate.post(host, port, path),
      );

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _withProxy(url, () => _delegate.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _withProxy(
        _uriFor(host, port, path),
        () => _delegate.put(host, port, path),
      );

  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _withProxy(url, () => _delegate.putUrl(url));

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _delegate.authenticate = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => _delegate.authenticateProxy = f;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _delegate.badCertificateCallback = callback;

  @override
  set findProxy(String Function(Uri url)? f) => _delegate.findProxy = f;

  @override
  bool get autoUncompress => _delegate.autoUncompress;

  @override
  set autoUncompress(bool value) => _delegate.autoUncompress = value;

  @override
  Duration? get connectionTimeout => _delegate.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _delegate.connectionTimeout = value;

  @override
  Duration get idleTimeout => _delegate.idleTimeout;

  @override
  set idleTimeout(Duration value) => _delegate.idleTimeout = value;

  @override
  int? get maxConnectionsPerHost => _delegate.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) =>
      _delegate.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _delegate.userAgent;

  @override
  set userAgent(String? value) => _delegate.userAgent = value;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => _delegate.connectionFactory = f;

  @override
  set keyLog(Function(String line)? callback) => _delegate.keyLog = callback;
}
