import 'dart:async';

import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/device_storage.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      expect(store.accountPortraitVersion, isNotNull);
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
      await store.refreshAccountProfile();
      expect(store.accountProfile?.displayName, 'reader');
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
      expect(store.accountPortraitVersion, isNull);
      expect(storage.values[AccountCache.key], before);
      expect(store.notice, isNull);
      account.profileLoader = () async => _newProfile;
      await store.refreshAccountProfile();
      expect(store.accountProfile?.displayName, '新暱稱');
      expect(account.profileReads, 2);
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
      expect(store.accountPortraitVersion, isNull);
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
    'startup and background return refresh without an official portal',
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
      expect(account.profileReads, 2);
      expect(store.accountPortraitVersion, isNot(firstVersion));
      expect(store.needsOfficialPortal, isFalse);
      expect(store.notice, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'portrait cache version changes the request even for the same avatar URL',
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
        return (image.image as NetworkImage).url;
      }

      final first = await portraitUrl(1);
      final second = await portraitUrl(2);
      expect(first, isNot(second));
      expect(Uri.parse(second).queryParameters, {
        'v': '3',
        '_baha_refresh': '2',
      });
      expect(tester.takeException(), isNull);
    },
  );
}
