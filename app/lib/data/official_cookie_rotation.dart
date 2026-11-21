import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class OfficialCookieRotation {
  static const _hosts = {
    'ani.gamer.com.tw',
    'api.gamer.com.tw',
    'wall.gamer.com.tw',
    'user.gamer.com.tw',
  };
  static Future<void>? _pending;
  static Future<void>? get pending => _pending;
  static int _generation = 0;
  static ({String first, String latest})? _chain;
  static int get generation => _generation;
  static void invalidate() {
    _generation++;
    _chain = null;
  }

  static String fingerprintValue(String token) {
    final chain = _chain;
    return chain != null && token == chain.latest ? chain.first : token;
  }

  static bool isLatest(String token) => token == _chain?.latest;

  @visibleForTesting
  static CookieManager? managerOverride;
  static CookieManager get manager => managerOverride ?? CookieManager.instance();

  static Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = (_pending ?? Future<void>.value()).then((_) => action());
    final settled = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _pending = settled;
    settled.then((_) {
      if (identical(_pending, settled)) _pending = null;
    });
    return result;
  }

  static Future<void> clear(Future<void> Function() action) {
    invalidate();
    return _enqueue(action);
  }

  static Future<bool> persist(
    Uri uri,
    io.Cookie cookie,
    bool hostOnly,
    String sentHeader,
    bool Function() isCurrent,
  ) async {
    final epoch = generation;
    try {
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !_hosts.contains(uri.host) ||
          cookie.name != 'BAHARUNE') {
        return false;
      }
      final platform = defaultTargetPlatform;
      if (kIsWeb ||
          (platform != TargetPlatform.android &&
              platform != TargetPlatform.windows &&
              platform != TargetPlatform.iOS)) {
        return false;
      }
      final domain = cookie.domain?.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
      if (hostOnly
          ? domain != null && domain != uri.host
          : domain != uri.host && domain != 'gamer.com.tw') {
        return false;
      }
      final slash = uri.path.lastIndexOf('/');
      final path = cookie.path?.startsWith('/') == true
          ? cookie.path!
          : slash <= 0 ? '/' : uri.path.substring(0, slash);
      final value = cookie.value;
      if (path.contains(RegExp(r'[;\x00-\x1f\x7f]')) ||
          value.contains(RegExp(r'[\x00-\x20\x7f";,\\]'))) {
        return false;
      }
      final sent = <String, String>{};
      for (final pair in sentHeader.split(';')) {
        final field = pair.trim();
        final equals = field.indexOf('=');
        final name = equals < 0 ? field : field.substring(0, equals);
        if (name != 'BAHARUNE' && name != 'BAHAID') continue;
        if (equals < 0 || equals == field.length - 1 || sent.containsKey(name)) {
          return false;
        }
        sent[name] = field.substring(equals + 1);
      }
      if (sent.length != 2) return false;

      final now = DateTime.now().millisecondsSinceEpoch;
      final maxAge = cookie.maxAge;
      // Anchor Max-Age at receipt. An expired write targets the exact cookie,
      // including on Windows where deletion by URL can match other scopes.
      final expires = maxAge == null
          ? cookie.expires?.millisecondsSinceEpoch
          : maxAge <= 0 ? 1000 : now + Duration(seconds: maxAge).inMilliseconds;
      if (value.isEmpty && (expires == null || expires > now)) return false;
      final secure = cookie.secure;
      final httpOnly = cookie.httpOnly;
      final sameSite = switch (cookie.sameSite) {
        io.SameSite.strict => HTTPCookieSameSitePolicy.STRICT,
        io.SameSite.lax => HTTPCookieSameSitePolicy.LAX,
        io.SameSite.none => HTTPCookieSameSitePolicy.NONE,
        null => null,
        _ => throw const FormatException('Unsupported SameSite'),
      };
      if (cookie.sameSite == io.SameSite.none && !secure) return false;
      final url = WebUri(uri.toString());
      return await _enqueue(() async {
        if (generation != epoch || !isCurrent()) return false;
        final store = manager;
        final current = await store.getCookies(url: url);
        final matched = <String>{};
        for (final item in current) {
          if (!sent.containsKey(item.name)) continue;
          // The iOS adapter returns domain-suffix matches across all paths.
          if (platform == TargetPlatform.iOS) {
            final scope = item.domain?.toLowerCase();
            final cookiePath = item.path;
            if (scope == null || cookiePath == null) return false;
            if (scope.startsWith('.')
                ? uri.host != scope.substring(1) && !uri.host.endsWith(scope)
                : uri.host != scope) {
              continue;
            }
            final requestPath = uri.path.isEmpty ? '/' : uri.path;
            if (requestPath != cookiePath &&
                !requestPath.startsWith(cookiePath.endsWith('/') ? cookiePath : '$cookiePath/')) {
              continue;
            }
          }
          if (item.value != sent[item.name] || !matched.add(item.name)) {
            return false;
          }
        }
        if (matched.length != 2 || generation != epoch || !isCurrent()) return false;
        // Android omits Domain when null. WebView2's CDP uses the URL for
        // host-only cookies and a leading dot for explicit domain cookies.
        final written = await store.setCookie(
          url: url,
          name: 'BAHARUNE',
          value: value.isEmpty ? sent['BAHARUNE']! : value,
          domain: hostOnly ? null : '.$domain',
          path: path,
          expiresDate: expires != null && expires <= now ? 1000 : expires,
          isSecure: secure,
          isHttpOnly: httpOnly,
          sameSite: sameSite,
        );
        if (written && epoch == generation) {
          _chain = expires != null && expires <= DateTime.now().millisecondsSinceEpoch
              ? null
              : (first: fingerprintValue(sent['BAHARUNE']!), latest: value);
        }
        return written;
      });
    } catch (_) {
      return false;
    }
  }
}
