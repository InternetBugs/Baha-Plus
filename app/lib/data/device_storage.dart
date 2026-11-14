import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';

abstract interface class DeviceStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> clearAccountData();
}

class PreferencesStorage implements DeviceStorage {
  final _preferences = SharedPreferencesAsync();
  @override
  Future<String?> read(String key) => _preferences.getString(key);
  @override
  Future<void> write(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<void> clearAccountData() async {
    final keys = (await _preferences.getKeys())
        .where(
          (key) =>
              key.startsWith('baha.account.') ||
              key.startsWith('baha.notifications.read.'),
        )
        .toSet();
    if (keys.isNotEmpty) await _preferences.clear(allowList: keys);
  }
}

class CatalogCache {
  CatalogCache(this.storage);
  final DeviceStorage storage;
  static const key = 'baha.catalog.v1';
  Future<Catalog?> load() async {
    try {
      final raw = await storage.read(key);
      if (raw == null || utf8.encode(raw).length >= 5000000) return null;
      return Catalog.fromJson(jsonDecode(raw) as Json);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Catalog catalog) async {
    if (!catalog.isValid) return;
    final encoded = catalog.encode();
    if (utf8.encode(encoded).length >= 5000000) return;
    await storage.write(key, encoded);
  }
}

/// A display-only snapshot. Authentication stays in the native Cookie store.
class AccountCache {
  AccountCache(this.storage);
  final DeviceStorage storage;
  static const key = 'baha.account.v1';

  Future<Json?> load() async {
    try {
      final raw = await storage.read(key);
      if (raw == null || utf8.encode(raw).length >= 5000000) return null;
      final snapshot = jsonDecode(raw) as Json;
      if (snapshot['profile'] != null) {
        AccountProfile.fromJson(snapshot['profile'] as Json);
      }
      final favorites = (snapshot['favorites'] as List)
          .map((item) => Anime.fromJson(item as Json))
          .toList();
      final history = (snapshot['history'] as List)
          .map((item) => WatchEntry.fromJson(item as Json))
          .toList();
      if (favorites.length > 10000 ||
          favorites.map((item) => item.id).toSet().length != favorites.length ||
          history.length > 1000 ||
          history.map((item) => item.anime.id).toSet().length !=
              history.length) {
        return null;
      }
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Json? snapshot) async {
    final value = snapshot == null ? '' : jsonEncode(snapshot);
    if (utf8.encode(value).length >= 5000000) {
      await storage.write(key, '');
      return;
    }
    await storage.write(key, value);
  }
}
