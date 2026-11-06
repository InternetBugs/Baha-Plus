import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';

abstract interface class DeviceStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PreferencesStorage implements DeviceStorage {
  final _preferences = SharedPreferencesAsync();
  @override
  Future<String?> read(String key) => _preferences.getString(key);
  @override
  Future<void> write(String key, String value) =>
      _preferences.setString(key, value);
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
