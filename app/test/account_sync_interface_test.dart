import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/ui/catalog_pages.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakeSearch, MemoryStorage;
import 'fake_account.dart';
import 'fake_metadata.dart';

void main() {
  for (final history in [true, false]) {
    testWidgets(
      '${history ? 'history' : 'favorites'} retries data without asking a confirmed account to log in',
      (tester) async {
        final account = FakeAccountApi()
          ..accountLoader = () async => {
            'profile': {'id': 'reader', 'displayName': '讀者'},
            'favorites': [],
            'history': [],
          };
        final store = (await tester.runAsync(
          () => AppStore.create(
            storage: MemoryStorage(),
            accountApi: account,
            metadataApi: FakeMetadata(),
            animeSearch: FakeSearch(),
          ),
        ))!;
        addTearDown(store.dispose);
        store.accountProfile = const AccountProfile(
          id: 'reader',
          displayName: '讀者',
        );
        store.accountNeedsRefresh = true;
        store.notice = store.t('accountSyncError');
        store.libraryFilter = 'favorites';
        var loginRequests = 0;
        await tester.pumpWidget(
          LiquidGlassWidgets.wrap(
            brightnessResolver: Theme.maybeBrightnessOf,
            theme: GlassThemeData.simple(quality: GlassQuality.standard),
            child: CupertinoApp(
              home: CupertinoPageScaffold(
                child: ListenableBuilder(
                  listenable: store,
                  builder: (context, _) => CustomScrollView(
                    slivers: [
                      if (history)
                        HistoryContent(store: store)
                      else
                        LibraryContent(
                          store: store,
                          openDetail: (_) {},
                          connectAccount: () => loginRequests++,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text(store.t('connectAccount')), findsNothing);
        expect(find.text(store.t('historyHint')), findsNothing);
        expect(find.text(store.t('accountSyncError')), findsOneWidget);
        await tester.tap(find.text(store.t('retry')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(account.accountReads, 1);
        expect(loginRequests, 0);
        expect(store.browserVisible, isFalse);
        expect(store.accountProfile?.id, 'reader');
        expect(store.accountSynced, isTrue);
        expect(store.notice, isNull);
        expect(find.text(store.t('connectAccount')), findsNothing);
        expect(find.text(store.t('accountSyncError')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
