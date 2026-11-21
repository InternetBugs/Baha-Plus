import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/community_widgets.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakeSearch, MemoryStorage;
import 'fake_account.dart';
import 'fake_metadata.dart';
import 'fake_playback.dart';

void main() {
  Future<void> frames(WidgetTester tester, {int count = 16}) async {
    for (var frame = 0; frame < count; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<AppStore> launch(
    WidgetTester tester, {
    Size size = const Size(400, 850),
    double textScale = 1,
    String language = 'zh-Hans',
    String appearance = 'light',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = (await tester.runAsync(
      () => AppStore.create(
        nativeHttpApiFactory: PendingNativeHttpApi.new,
        metadataApi: FakeMetadata(),
        accountApi: FakeAccountApi(),
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
      ),
    ))!;
    addTearDown(store.dispose);
    await store.setLanguage(language);
    await store.setAppearance(appearance);
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: BahaPlusApp(store: store, mountPortal: false),
        ),
      ),
    );
    await frames(tester);
    return store;
  }

  Future<void> openAccount(WidgetTester tester) async {
    await tester.tap(find.byType(AccountAvatar).hitTestable());
    await frames(tester);
  }

  testWidgets(
    'account language and appearance pickers use floating Liquid Glass cards with checkmarks',
    (tester) async {
      final store = await launch(tester);
      await openAccount(tester);

      final languageRow = find.byKey(const ValueKey('account-language-picker'));
      await tester.scrollUntilVisible(
        languageRow,
        150,
        scrollable: find.byType(Scrollable).last,
      );
      await frames(tester);
      await tester.tap(languageRow);
      await frames(tester);

      expect(find.byType(CupertinoActionSheet), findsNothing);
      final hans = find.byKey(const ValueKey('language-option-zh-Hans'));
      final hant = find.byKey(const ValueKey('language-option-zh-Hant'));
      expect(hans, findsOneWidget);
      expect(hant, findsOneWidget);
      expect(
        find.descendant(
          of: hans,
          matching: find.byIcon(CupertinoIcons.checkmark),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: hant,
          matching: find.byIcon(CupertinoIcons.checkmark),
        ),
        findsNothing,
      );
      // Selected and unselected labels share the same vertical text baseline.
      expect(
        tester
            .getTopLeft(
              find.descendant(of: hans, matching: find.text('简体中文')),
            )
            .dx,
        closeTo(
          tester
              .getTopLeft(
                find.descendant(of: hant, matching: find.text('繁體中文')),
              )
              .dx,
          .5,
        ),
      );
      // Floating card aligns to the right side of the row instead of spanning full width.
      final menuRect = tester.getRect(hans);
      expect(menuRect.left, greaterThan(100));
      expect(menuRect.right, lessThanOrEqualTo(400));

      await tester.tap(hant);
      await frames(tester);
      expect(store.language, 'zh-Hant');
      expect(find.byKey(const ValueKey('language-option-zh-Hant')), findsNothing);

      final appearanceRow = find.byKey(
        const ValueKey('account-appearance-picker'),
      );
      await tester.tap(appearanceRow);
      await frames(tester);
      expect(find.byType(CupertinoActionSheet), findsNothing);
      final lightOption = find.byKey(const ValueKey('appearance-option-light'));
      final darkOption = find.byKey(const ValueKey('appearance-option-dark'));
      expect(
        find.descendant(
          of: lightOption,
          matching: find.byIcon(CupertinoIcons.checkmark),
        ),
        findsOneWidget,
      );
      await tester.tap(darkOption);
      await frames(tester);
      expect(store.appearance, 'dark');
      expect(
        Theme.of(tester.element(appearanceRow)).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'system back and outside tap dismiss the floating settings card without closing AccountPage',
    (tester) async {
      final store = await launch(tester);
      await openAccount(tester);

      final languageRow = find.byKey(const ValueKey('account-language-picker'));
      await tester.scrollUntilVisible(
        languageRow,
        150,
        scrollable: find.byType(Scrollable).last,
      );
      await frames(tester);

      await tester.tap(languageRow);
      await frames(tester);
      expect(
        find.byKey(const ValueKey('language-option-zh-Hant')),
        findsOneWidget,
      );

      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(
        find.byKey(const ValueKey('language-option-zh-Hant')),
        findsNothing,
      );
      expect(find.byType(GlassModalSheet), findsOneWidget);

      await tester.tap(languageRow);
      await frames(tester);
      expect(
        find.byKey(const ValueKey('language-option-zh-Hant')),
        findsOneWidget,
      );

      await tester.tapAt(const Offset(24, 120));
      await frames(tester);
      expect(
        find.byKey(const ValueKey('language-option-zh-Hant')),
        findsNothing,
      );
      expect(find.byType(GlassModalSheet), findsOneWidget);
      expect(store.language, 'zh-Hans');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'floating settings cards stay within bounds on compact viewports with large text',
    (tester) async {
      await launch(
        tester,
        size: const Size(320, 640),
        textScale: 1.5,
      );
      await openAccount(tester);

      final appearanceRow = find.byKey(
        const ValueKey('account-appearance-picker'),
      );
      await tester.scrollUntilVisible(
        appearanceRow,
        150,
        scrollable: find.byType(Scrollable).last,
      );
      await frames(tester);
      await tester.tap(appearanceRow);
      await frames(tester);

      final darkOption = find.byKey(const ValueKey('appearance-option-dark'));
      expect(darkOption, findsOneWidget);
      final rect = tester.getRect(darkOption);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.bottom, lessThanOrEqualTo(640));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'BoardEpisodePicker opens a Liquid Glass option menu with checkmark',
    (tester) async {
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = (await tester.runAsync(
        () => AppStore.create(
          metadataApi: FakeMetadata(),
          storage: MemoryStorage(),
          animeSearch: FakeSearch(),
        ),
      ))!;
      addTearDown(store.dispose);
      Episode? selected;
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: BoardEpisodePicker(
                  store: store,
                  videoId: '20',
                  episodes: const [
                    Episode(id: '20', label: '1'),
                    Episode(id: '21', label: '2'),
                  ],
                  onSelected: (episode) => selected = episode,
                ),
              ),
            ),
          ),
        ),
      );
      await frames(tester);
      await tester.tap(find.byKey(const ValueKey('board-episode-selector')));
      await frames(tester);
      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('board-select-20')),
          matching: find.byIcon(CupertinoIcons.checkmark),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('board-select-21')));
      await frames(tester);
      expect(selected?.id, '21');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('skip OP switch toggles and persists in device preferences', (
    tester,
  ) async {
    final store = await launch(tester);
    await openAccount(tester);
    final row = find.byKey(const ValueKey('account-skip-op-switch'));
    await tester.scrollUntilVisible(
      row,
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await frames(tester);
    expect(store.skipOpLongPress, isTrue);
    expect(find.text(store.t('skipOpLongPress')), findsOneWidget);

    await tester.tap(row);
    await frames(tester);
    expect(store.skipOpLongPress, isFalse);
    expect(
      (store.storage as MemoryStorage).values['baha.device.skipOpLongPress'],
      '0',
    );

    await tester.tap(find.byType(CupertinoSwitch));
    await frames(tester);
    expect(store.skipOpLongPress, isTrue);
    expect(
      (store.storage as MemoryStorage).values['baha.device.skipOpLongPress'],
      '1',
    );

    await tester.tap(find.byType(CupertinoSwitch));
    await frames(tester);
    expect(store.skipOpLongPress, isFalse);
    expect(
      (store.storage as MemoryStorage).values['baha.device.skipOpLongPress'],
      '0',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('skip OP preference loads from device storage', (tester) async {
    final storage = MemoryStorage()
      ..values['baha.device.skipOpLongPress'] = '0';
    final store = (await tester.runAsync(
      () => AppStore.create(
        storage: storage,
        metadataApi: FakeMetadata(),
        animeSearch: FakeSearch(),
      ),
    ))!;
    addTearDown(store.dispose);
    expect(store.skipOpLongPress, isFalse);
  });
}
