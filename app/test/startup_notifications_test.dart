import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/app_updates.dart';
import 'package:baha_plus/data/device_storage.dart';
import 'package:baha_plus/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakeSearch, MemoryStorage;
import 'fake_account.dart';
import 'fake_metadata.dart';

const _profile = {
  'id': 'reader',
  'displayName': '讀者',
  'avatar': 'https://avatar2.bahamut.com.tw/reader.png?v=3',
};
const _notification = {
  'id': 'episode:123',
  'title': '測試動畫 [123] 更新囉！',
  'videoId': '123',
  'time': '1天前',
};

void main() {
  Future<void> frames(WidgetTester tester) async {
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(AppStore, FakeAccountApi)> setup({required bool signedIn}) async {
    final storage = MemoryStorage();
    if (signedIn) {
      await AccountCache(storage).save({
        'profile': _profile,
        'favorites': <Json>[],
        'history': <Json>[],
        'profileCheckedAt': DateTime.now().millisecondsSinceEpoch,
      });
    }
    final account = FakeAccountApi();
    final store = await AppStore.create(
      storage: storage,
      accountApi: account,
      metadataApi: FakeMetadata(),
      animeSearch: FakeSearch(),
      updates: AppUpdates(
        versionLoader: () async => '0.5.0',
        client: MockClient((_) async => http.Response('', 404)),
      ),
    );
    addTearDown(store.dispose);
    return (store, account);
  }

  Future<void> launch(WidgetTester tester, AppStore store) async {
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
    await frames(tester);
  }

  Iterable<Json> notificationsRequests(FakeAccountApi account) =>
      account.communityRequests.where(
        (request) => request['action'] == 'notifications',
      );

  testWidgets('startup populates the bell once for a signed-in account', (
    tester,
  ) async {
    final (store, account) = (await tester.runAsync(
      () => setup(signedIn: true),
    ))!;
    account.communityHandler = (action, args) async => {
      'ok': true,
      'owner': 'reader',
      'items': [_notification],
    };
    expect(store.hasAccount, isTrue);

    await launch(tester, store);

    expect(notificationsRequests(account), hasLength(1));
    expect(store.notifications.single.id, 'episode:123');
    expect(store.unreadNotifications, 1);
    expect(store.notificationsError, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup never fetches notifications without an account', (
    tester,
  ) async {
    final (store, account) = (await tester.runAsync(
      () => setup(signedIn: false),
    ))!;
    expect(store.hasAccount, isFalse);

    await launch(tester, store);

    expect(notificationsRequests(account), isEmpty);
    expect(store.notificationsError, isNull);
    expect(tester.takeException(), isNull);
  });
}
