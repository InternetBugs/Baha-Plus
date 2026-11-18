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
    await AccountCache(storage).save({
      'profile': _oldProfile,
      'favorites': [
        const Anime(
          id: '10',
          title: '動畫',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
        ).toJson(),
      ],
      'history': [],
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
            ...snapshot,
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
      expect(store.hasAccount, isFalse);
      expect(store.favorites, isEmpty);
      expect(await AccountCache(storage).load(), isNull);
    },
  );

  test(
    'a late refresh cannot restore an account after starting login',
    () async {
      final (store, account, _) = await setup();
      final pending = Completer<Json?>();
      account.profileLoader = () => pending.future;
      final reading = store.refreshAccountProfile();
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
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
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
