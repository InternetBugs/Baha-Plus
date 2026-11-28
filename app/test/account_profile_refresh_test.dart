import 'dart:async';

import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/device_storage.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakeSearch, MemoryStorage;
import 'fake_account.dart';
import 'fake_metadata.dart';

const _oldProfile = {
  'id': 'reader',
  'displayName': '舊暱稱',
  'avatar': 'https://avatar2.bahamut.com.tw/reader.png?v=3',
};
const _newProfile = {
  'id': 'reader',
  'displayName': '新暱稱',
  'avatar': 'https://avatar2.bahamut.com.tw/reader.png?v=3',
};
const _otherProfile = {'id': 'other', 'displayName': '另一位讀者'};

class _FileInfo extends Fake implements FileInfo {}

class _PortraitCache extends Fake implements BaseCacheManager {
  final checks = <String>[];
  bool offline = false;

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) async {
    checks.add(url);
    expect(authHeaders, containsPair('Cache-Control', 'no-cache'));
    if (offline) throw StateError('offline');
    return _FileInfo();
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PortraitCache portraits;
  setUp(() {
    portraits = _PortraitCache();
    CachedNetworkImageProvider.defaultCacheManager = portraits;
  });

  Future<(AppStore, FakeAccountApi, MemoryStorage)> setup() async {
    final storage = MemoryStorage();
    final anime = const Anime(
      id: '10',
      title: '動畫',
      cover: 'https://p2.bahamut.com.tw/10.jpg',
    ).toJson();
    await AccountCache(storage).save({
      'profile': _oldProfile,
      'favorites': [anime],
      'history': [
        {'anime': anime, 'videoId': '20', 'episodeLabel': '1'},
      ],
    });
    final account = FakeAccountApi();
    final store = await AppStore.create(
      storage: storage,
      accountApi: account,
      metadataApi: FakeMetadata(),
      animeSearch: FakeSearch(),
    );
    addTearDown(store.dispose);
    return (store, account, storage);
  }

  test(
    'refresh keeps cached data visible, deduplicates and persists the result',
    () async {
      final (store, account, storage) = await setup();
      final pending = Completer<Json?>();
      account.profileLoader = () => pending.future;
      final operation = store.operation.id;
      final refreshing = store.refreshAccountProfile();
      await store.refreshAccountProfile();
      expect(account.profileReads, 1);
      expect(store.accountProfile?.displayName, '舊暱稱');
      pending.complete(_newProfile);
      await refreshing;
      expect(store.accountProfile?.displayName, '新暱稱');
      expect(store.favorites.single.id, '10');
      expect(store.operation.id, operation);
      expect(store.needsOfficialPortal, isFalse);
      expect(account.accountReads, 0);
      final cached = (await AccountCache(storage).load())!;
      expect(cached['profile'], _newProfile);
      expect((cached['favorites'] as List).single['id'], '10');
      account.profileLoader = () async => {
        ..._newProfile,
        'displayName': 'reader',
      };
      await store.refreshAccountProfile(force: true);
      expect(store.accountProfile?.displayName, 'reader');
      expect(portraits.checks, [_newProfile['avatar']]);
    },
  );

  test(
    'failed automatic refresh silently preserves the existing cache',
    () async {
      final (store, account, storage) = await setup();
      final before = storage.values[AccountCache.key];
      account.profileLoader = () async =>
          throw const CommunityException('network');
      await store.refreshAccountProfile();
      expect(store.accountProfile?.toJson(), _oldProfile);
      expect(store.accountPortraitVersion, 0);
      expect(storage.values[AccountCache.key], before);
      expect(store.notice, isNull);
      account.profileLoader = () async => _newProfile;
      await store.refreshAccountProfile();
      expect(store.accountProfile?.displayName, '新暱稱');
      expect(account.profileReads, 2);
    },
  );

  test(
    'a fresh profile survives restart; expired profiles are refreshed',
    () async {
      final (store, account, storage) = await setup();
      account.profileLoader = () async => _newProfile;
      await store.refreshAccountProfile();
      final snapshot = (await AccountCache(storage).load())!;
      for (final expired in [false, true]) {
        if (expired) {
          await AccountCache(storage).save({
            ...snapshot.toJson(),
            'profileCheckedAt': DateTime.now()
                .subtract(const Duration(days: 1))
                .millisecondsSinceEpoch,
          });
        }
        final restarted = await AppStore.create(
          storage: storage,
          accountApi: account,
        );
        addTearDown(restarted.dispose);
        await restarted.refreshAccountProfile();
        expect(account.profileReads, expired ? 2 : 1);
        expect(restarted.accountProfile?.toJson(), _newProfile);
      }
    },
  );

  test(
    'failed manual portrait validation preserves the snapshot and allows retry',
    () async {
      final (store, account, storage) = await setup();
      account.profileLoader = () async => _newProfile;
      final before = storage.values[AccountCache.key];
      portraits.offline = true;
      expect(await store.refreshAccountProfile(force: true), isFalse);
      expect(store.accountProfile?.toJson(), _oldProfile);
      expect(storage.values[AccountCache.key], before);
      portraits.offline = false;
      expect(await store.refreshAccountProfile(force: true), isTrue);
      expect(store.accountProfile?.toJson(), _newProfile);
    },
  );

  test('a confirmed guest clears the old profile and snapshot', () async {
    final (store, account, storage) = await setup();
    account.profileLoader = () async => null;
    await store.refreshAccountProfile();
    expect(account.profileReads, 2);
    expect(store.accountProfile, isNull);
    expect(store.favorites, isEmpty);
    expect(await AccountCache(storage).load(), isNull);
    expect(store.notice, isNull);
  });

  test(
    'a confirmed guest clears a legacy snapshot without a profile',
    () async {
      final (store, account, storage) = await setup();
      store.accountProfile = null;
      account.profileLoader = () async => null;
      await store.refreshAccountProfile();
      expect(account.profileReads, 2);
      expect(store.hasAccount, isFalse);
      expect(store.favorites, isEmpty);
      expect(await AccountCache(storage).load(), isNull);
    },
  );

  for (final sync in [false, true]) {
    final source = sync ? 'collection sync' : 'profile refresh';

    Future<void> readAfterGuest(
      AppStore store,
      FakeAccountApi account,
      Future<Json?> Function() confirm,
    ) async {
      account.accountLoader = () async => null;
      account.profileLoader = () async {
        if (!sync && account.profileReads == 1) return null;
        return confirm();
      };
      if (sync) {
        await store.syncAccount();
      } else {
        await store.refreshAccountProfile();
      }
    }

    test('$source recovers a cached owner after one guest result', () async {
      final (store, account, storage) = await setup();
      final started = Completer<void>(), result = Completer<Json?>();
      final before = storage.values[AccountCache.key];
      final reading = readAfterGuest(store, account, () {
        started.complete();
        return result.future;
      });
      await started.future;
      expect(store.accountProfile?.toJson(), _oldProfile);
      expect(store.favorites.single.id, '10');
      expect(store.history.single.videoId, '20');
      expect(storage.values[AccountCache.key], before);
      result.complete({..._newProfile, 'id': 'READER'});
      await reading;
      expect(account.profileReads, sync ? 1 : 2);
      expect(account.accountReads, sync ? 1 : 0);
      expect(store.accountSynced, isTrue);
      expect(store.accountNeedsRefresh, sync);
      final cached = (await AccountCache(storage).load())!;
      expect(cached['profile'], {..._newProfile, 'id': 'READER'});
      expect((cached['favorites'] as List).single['id'], '10');
      expect((cached['history'] as List).single['videoId'], '20');
    });

    test('$source isolates collections after switching owners', () async {
      final (store, account, storage) = await setup();
      await readAfterGuest(store, account, () async => _otherProfile);
      expect(store.accountProfile?.toJson(), _otherProfile);
      expect(store.favorites, isEmpty);
      expect(store.history, isEmpty);
      expect(store.accountSynced, isFalse);
      expect(store.accountNeedsRefresh, isTrue);
      final restored = await AppStore.create(storage: storage);
      addTearDown(restored.dispose);
      expect(restored.accountProfile?.toJson(), _otherProfile);
      expect(restored.favorites, isEmpty);
      expect(restored.history, isEmpty);
      expect(restored.accountSynced, isFalse);
      expect(restored.accountNeedsRefresh, isTrue);
    });

    test('$source preserves the cache when confirmation fails', () async {
      final (store, account, storage) = await setup();
      final before = storage.values[AccountCache.key];
      await readAfterGuest(
        store,
        account,
        () async => throw const CommunityException('network'),
      );
      expect(account.profileReads, sync ? 1 : 2);
      expect(store.accountProfile?.toJson(), _oldProfile);
      expect(store.favorites.single.id, '10');
      expect(store.history.single.videoId, '20');
      expect(storage.values[AccountCache.key], before);
      expect(store.accountNeedsRefresh, sync);
      expect(store.notice, sync ? store.t('accountSyncError') : null);
    });
  }

  test(
    'a guest confirmation cannot clear a newer authenticated sync',
    () async {
      final (store, account, storage) = await setup();
      final started = Completer<void>(), result = Completer<Json?>();
      account.profileLoader = () async {
        if (account.profileReads == 1) return null;
        started.complete();
        return result.future;
      };
      final checking = store.refreshAccountProfile();
      await started.future;
      account.accountLoader = () async => {
        'profile': _newProfile,
        'favorites': [],
        'history': [],
      };
      await store.syncAccount();
      result.complete(null);
      expect(await checking, isFalse);
      expect(store.accountProfile?.toJson(), _newProfile);
      expect((await AccountCache(storage).load())!['profile'], _newProfile);
      expect(store.accountNeedsRefresh, isFalse);
    },
  );

  test('a delayed sync confirmation cannot restore a previous owner', () async {
    final (store, account, storage) = await setup();
    final started = Completer<void>(), result = Completer<Json?>();
    account.accountLoader = () async => null;
    account.profileLoader = () {
      started.complete();
      return result.future;
    };
    final syncing = store.syncAccount();
    await started.future;
    account.profileLoader = () async => _otherProfile;
    expect(await store.refreshAccountProfile(), isTrue);
    result.complete(_oldProfile);
    await syncing;
    expect(store.accountProfile?.toJson(), _otherProfile);
    expect(store.favorites, isEmpty);
    expect(store.history, isEmpty);
    expect((await AccountCache(storage).load())!['profile'], _otherProfile);
  });

  test('logout invalidates an outstanding guest confirmation', () async {
    final (store, account, storage) = await setup();
    final started = Completer<void>(), result = Completer<Json?>();
    account.accountLoader = () async => null;
    account.profileLoader = () {
      started.complete();
      return result.future;
    };
    final syncing = store.syncAccount();
    await started.future;
    expect(await store.logoutAccount(), isTrue);
    result.complete(_newProfile);
    await syncing;
    expect(account.profileReads, 1);
    expect(store.hasAccount, isFalse);
    expect(await AccountCache(storage).load(), isNull);
  });

  test('an initial guest refresh needs only one profile read', () async {
    final api = FakeAccountApi()..profileLoader = () async => null;
    final store = await AppStore.create(
      storage: MemoryStorage(),
      accountApi: api,
    );
    addTearDown(store.dispose);
    expect(await store.refreshAccountProfile(), isTrue);
    expect(api.profileReads, 1);
    expect(store.hasAccount, isFalse);
  });

  test(
    'a late guest confirmation cannot restore an account after starting login',
    () async {
      final (store, account, _) = await setup();
      final started = Completer<void>(), pending = Completer<Json?>();
      account.profileLoader = () async {
        if (account.profileReads == 1) return null;
        started.complete();
        return pending.future;
      };
      final reading = store.refreshAccountProfile();
      await started.future;
      await store.connectAccount();
      pending.complete(_newProfile);
      await reading;
      expect(store.accountProfile, isNull);
      expect(store.accountPortraitVersion, 0);
    },
  );

  test(
    'a slower collection sync preserves the newly refreshed nickname',
    () async {
      final (store, account, storage) = await setup();
      final pending = Completer<Json?>();
      account.accountLoader = () => pending.future;
      account.profileLoader = () async => _newProfile;
      final syncing = store.syncAccount();
      await store.refreshAccountProfile();
      pending.complete({
        'profile': _oldProfile,
        'favorites': [],
        'history': [],
      });
      await syncing;
      expect(store.accountProfile?.displayName, '新暱稱');
      expect(store.favorites, isEmpty);
      expect((await AccountCache(storage).load())!['profile'], _newProfile);
      await store.syncAccount();
      expect(store.accountProfile?.displayName, '新暱稱');
    },
  );

  testWidgets(
    'background return reuses fresh data; the account refresh button bypasses it',
    (tester) async {
      final (store, account, _) = (await tester.runAsync(setup))!;
      account.profileLoader = () async => _newProfile;
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: BahaPlusApp(store: store, mountPortal: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(account.profileReads, 1);
      expect(store.accountProfile?.displayName, '新暱稱');
      final firstVersion = store.accountPortraitVersion;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(account.profileReads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
      expect(account.profileReads, 1);
      expect(store.accountPortraitVersion, firstVersion);
      await tester.tap(find.byType(AccountAvatar).hitTestable());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text(store.t('refreshProfile')));
      await tester.pump();
      expect(account.profileReads, 2);
      expect(portraits.checks, [_newProfile['avatar']]);
      expect(store.needsOfficialPortal, isFalse);
      expect(store.notice, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rebuilding a refreshed portrait reuses the exact official disk cache key',
    (tester) async {
      Future<String> portraitUrl(int version) async {
        await tester.pumpWidget(
          CupertinoApp(
            home: AccountPortrait(
              profile: AccountProfile.fromJson(_oldProfile),
              cacheVersion: version,
            ),
          ),
        );
        final image = tester.widget<Image>(find.byType(Image));
        return (image.image as CachedNetworkImageProvider).url;
      }

      final first = await portraitUrl(1);
      final second = await portraitUrl(2);
      expect(first, _oldProfile['avatar']);
      expect(second, first);
      expect(tester.takeException(), isNull);
    },
  );
}
