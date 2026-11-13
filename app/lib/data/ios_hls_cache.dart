import 'package:flutter/services.dart';

/// A capability URL for the native, loopback-only HLS cache.
class HlsCacheEndpoint {
  const HlsCacheEndpoint(this.base, this.url);
  final String base, url;
}

class IOSHlsCache {
  IOSHlsCache({
    MethodChannel channel = const MethodChannel(
      'app.bahaplus.mobile/hls_cache',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;
  String? _document;
  double? _lastPosition;
  String? get document => _document;
  bool _applicationActive = true;

  Future<void> setApplicationActive(bool active) async {
    if (_applicationActive == active) return;
    _applicationActive = active;
    try {
      await _channel.invokeMethod<void>('setApplicationActive', {
        'active': active,
      });
    } on MissingPluginException {
      // Other platforms do not use the optional loopback cache.
    } on PlatformException {
      // Native lifecycle notifications also stop downloads on iOS.
    }
  }

  static bool validSource(String source) {
    final uri = Uri.tryParse(source);
    return source.length <= 4096 &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'bahamut.akamaized.net' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        uri.path.toLowerCase().endsWith('.m3u8');
  }

  Future<HlsCacheEndpoint?> prepare({
    required String document,
    required String videoId,
    required String source,
    List<String> additionalSources = const [],
  }) async {
    if (!RegExp(r'^[0-9a-f]{48}$').hasMatch(document) ||
        !RegExp(r'^[0-9]{1,10}$').hasMatch(videoId) ||
        !validSource(source) ||
        additionalSources.length > 20 ||
        additionalSources.any((value) => !validSource(value))) {
      return null;
    }
    if (_document != document) _lastPosition = null;
    _document = document;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'prepare',
        {'document': document, 'videoId': videoId, 'source': source},
      );
      if (_document != document || result == null) return null;
      final rawBase = result['base'];
      final rawUrl = result['url'];
      if (rawBase is! String || rawUrl is! String) {
        await stop(document);
        return null;
      }
      final base = Uri.tryParse(rawBase);
      final url = Uri.tryParse(rawUrl);
      if (base == null ||
          url == null ||
          base.scheme != 'http' ||
          base.host != 'localhost' ||
          base.port < 1024 ||
          base.port > 65535 ||
          base.userInfo.isNotEmpty ||
          base.hasQuery ||
          base.hasFragment ||
          !RegExp(
            r'^/[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}/$',
          ).hasMatch(base.path) ||
          url.scheme != 'http' ||
          url.host != 'localhost' ||
          url.port != base.port ||
          url.origin != base.origin ||
          !url.path.startsWith(base.path) ||
          url.userInfo.isNotEmpty ||
          url.hasFragment ||
          url.queryParameters['u'] != source) {
        await stop(document);
        return null;
      }
      for (final variant in additionalSources.toSet()..remove(source)) {
        if (_document != document) return null;
        final registered = await prepare(
          document: document,
          videoId: videoId,
          source: variant,
        );
        if (registered == null || registered.base != base.toString()) {
          if (_document == document) await stop(document);
          return null;
        }
      }
      return HlsCacheEndpoint(base.toString(), url.toString());
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> update(String document, double position) async {
    if (!_applicationActive ||
        _document != document ||
        !position.isFinite ||
        position < 0) {
      return;
    }
    if (_lastPosition != null && (position - _lastPosition!).abs() < 5) return;
    _lastPosition = position;
    try {
      await _channel.invokeMethod<void>('update', {
        'document': document,
        'position': position,
      });
    } on MissingPluginException {
      // Older native binaries retain their original official playback.
    } on PlatformException {
      // A failed speculative download must not stop playback.
    }
  }

  Future<void> stop(String document) async {
    if (_document == document) {
      _document = null;
      _lastPosition = null;
    }
    try {
      await _channel.invokeMethod<void>('stop', {'document': document});
    } on MissingPluginException {
      // The native cache is optional on other platforms.
    } on PlatformException {
      // The next native session also cancels work belonging to the old one.
    }
  }
}
