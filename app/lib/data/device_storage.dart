import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';

abstract interface class DeviceStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> clearAccountData();
}

abstract interface class BatchDeviceStorage implements DeviceStorage {
  Future<Map<String, String>> readAll(Set<String> keys);
}

class PreferencesStorage implements BatchDeviceStorage {
  PreferencesStorage({
    Future<Directory> Function()? directoryLoader,
    SharedPreferencesAsync? preferences,
  }) : _directoryLoader = directoryLoader ?? getApplicationSupportDirectory,
       _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  final Future<Directory> Function() _directoryLoader;
  Future<Directory>? _directory;
  final _blobOperations = <String, Future<void>>{};
  static const _blobKeys = {CatalogCache.key, AccountCache.key};

  @override
  Future<Map<String, String>> readAll(Set<String> keys) async {
    final values = await _preferences.getAll(
      allowList: keys.difference(_blobKeys),
    );
    final blobs = await Future.wait([
      for (final key in keys.intersection(_blobKeys))
        read(key).then((value) => MapEntry(key, value)),
    ]);
    return {
      for (final entry in values.entries)
        if (entry.value is String) entry.key: entry.value as String,
      for (final entry in blobs) entry.key: ?entry.value,
    };
  }

  @override
  Future<String?> read(String key) {
    if (!_blobKeys.contains(key)) return _preferences.getString(key);
    return _withBlob(key, (file) async {
      if (await file.exists()) return file.readAsString();
      final legacy = await _preferences.getString(key);
      if (legacy != null) {
        try {
          await _replace(file, legacy);
        } on FileSystemException {
          return legacy;
        }
        await _preferences.remove(key);
      }
      return legacy;
    });
  }

  @override
  Future<void> write(String key, String value) {
    if (!_blobKeys.contains(key)) return _preferences.setString(key, value);
    return _withBlob(key, (file) async {
      await _replace(file, value);
      await _preferences.remove(key);
    });
  }

  Future<T> _withBlob<T>(String key, Future<T> Function(File) action) {
    final pending = (_blobOperations[key] ?? Future<void>.value()).then((
      _,
    ) async {
      final directory = await (_directory ??= _directoryLoader().catchError((
        Object error,
      ) {
        _directory = null;
        throw error;
      }));
      return action(File('${directory.path}/$key.json'));
    });
    final settled = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _blobOperations[key] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_blobOperations[key], settled)) {
          _blobOperations.remove(key);
        }
      }),
    );
    return pending;
  }

  static Future<void> _replace(File file, String value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> clearAccountData() async {
    await _withBlob(AccountCache.key, (file) async {
      await _preferences.remove(AccountCache.key);
      for (final target in [file, File('${file.path}.tmp')]) {
        if (await target.exists()) await target.delete();
      }
    });
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

bool _tooLarge(String raw) =>
    raw.length * 3 >= 5000000 && utf8.encode(raw).length >= 5000000;

class CatalogCache {
  CatalogCache(this.storage);
  final DeviceStorage storage;
  static const key = 'baha.catalog.v1';
  Future<Catalog?> load() async {
    try {
      final raw = await storage.read(key);
      if (raw == null || _tooLarge(raw)) return null;
      return Catalog.fromJson(jsonDecode(raw) as Json);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Catalog catalog) async {
    if (!catalog.isValid) return;
    final encoded = catalog.encode();
    if (_tooLarge(encoded)) return;
    await storage.write(key, encoded);
  }
}

class AccountSnapshot {
  const AccountSnapshot({
    this.profile,
    required this.favorites,
    required this.history,
    this.collectionsSynced = true,
    this.profileCheckedAt,
  });

  factory AccountSnapshot.fromJson(Json json) {
    final favorites = (json['favorites'] as List)
        .map((item) => Anime.fromJson(item as Json))
        .toList();
    final history = (json['history'] as List)
        .map((item) => WatchEntry.fromJson(item as Json))
        .toList();
    if (favorites.length > 10000 ||
        favorites.map((item) => item.id).toSet().length != favorites.length ||
        history.length > 1000 ||
        history.map((item) => item.anime.id).toSet().length != history.length) {
      throw const FormatException('Invalid account snapshot');
    }
    return AccountSnapshot(
      profile: json['profile'] == null
          ? null
          : AccountProfile.fromJson(json['profile'] as Json),
      favorites: favorites,
      history: history,
      collectionsSynced: json['collectionsSynced'] != false,
      profileCheckedAt: json['profileCheckedAt'] is int
          ? json['profileCheckedAt'] as int
          : null,
    );
  }

  final AccountProfile? profile;
  final List<Anime> favorites;
  final List<WatchEntry> history;
  final bool collectionsSynced;
  final int? profileCheckedAt;

  Json toJson() => {
    'profile': profile?.toJson(),
    'favorites': [for (final item in favorites) item.toJson()],
    'history': [for (final item in history) item.toJson()],
    if (!collectionsSynced) 'collectionsSynced': false,
    'profileCheckedAt': ?profileCheckedAt,
  };

  dynamic operator [](String key) => toJson()[key];
}

/// A display-only snapshot. Authentication stays in the native Cookie store.
class AccountCache {
  AccountCache(this.storage);
  final DeviceStorage storage;
  static const key = 'baha.account.v1';

  Future<AccountSnapshot?> load() async {
    try {
      final raw = await storage.read(key);
      if (raw == null || raw.isEmpty || _tooLarge(raw)) return null;
      return AccountSnapshot.fromJson(jsonDecode(raw) as Json);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Json? snapshot) async {
    final value = snapshot == null ? '' : jsonEncode(snapshot);
    if (_tooLarge(value)) {
      await storage.write(key, '');
      return;
    }
    await storage.write(key, value);
  }
}
