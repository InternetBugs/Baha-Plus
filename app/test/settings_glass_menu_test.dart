import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/account_page.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/glass_alert.dart';
import 'package:baha_plus/ui/glass_settings_menu.dart';
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
    'account glass style picker swaps the glass tier and persists it',
    (tester) async {
      final store = await launch(tester);
      await openAccount(tester);

      final glassRow = find.byKey(
        const ValueKey('account-glass-style-picker'),
      );
      await tester.scrollUntilVisible(
        glassRow,
        150,
        scrollable: find.byType(Scrollable).last,
      );
      await frames(tester);
      await tester.tap(glassRow);
      await frames(tester);

      final standardOption = find.byKey(
        const ValueKey('glass-style-option-standard'),
      );
      final premiumOption = find.byKey(
        const ValueKey('glass-style-option-premium'),
      );
      final performanceOption = find.byKey(
        const ValueKey('glass-style-option-performance'),
      );
      expect(premiumOption, findsOneWidget);
      expect(performanceOption, findsOneWidget);
      expect(
        find.descendant(
          of: standardOption,
          matching: find.byIcon(CupertinoIcons.checkmark),
        ),
        findsOneWidget,
      );

      await tester.tap(premiumOption);
      await frames(tester);
      expect(store.glassStyle, 'premium');
      expect(await store.storage.read('baha.device.glass'), 'premium');
      expect(
        GlassThemeData.of(
          tester.element(find.byType(AccountPage)),
        ).qualityFor(tester.element(find.byType(AccountPage))),
        GlassQuality.premium,
      );
      expect(
        find.byKey(const ValueKey('glass-style-option-premium')),
        findsNothing,
      );
      await tester.tap(glassRow);
      await frames(tester);
      await tester.tap(performanceOption);
      await frames(tester);
      expect(store.glassStyle, 'performance');
      expect(await store.storage.read('baha.device.glass'), 'performance');
      expect(
        GlassThemeData.of(
          tester.element(find.byType(AccountPage)),
        ).qualityFor(tester.element(find.byType(AccountPage))),
        GlassQuality.minimal,
      );
      // The settings sheet keeps rendering on the shader-free minimal tier.
      expect(find.text(store.t('glassStyle')), findsOneWidget);
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
      await Scrollable.ensureVisible(
        tester.element(appearanceRow),
        alignment: 0.5,
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

  testWidgets('skip OP switch toggles and persists in device preferences', (
    tester,
  ) async {
    final store = await launch(tester);
    await openAccount(tester);
    final row = find.byKey(const ValueKey('account-skip-op-switch'));
    final toggle = find.descendant(
      of: row,
      matching: find.byType(GlassSwitch),
    );
    await tester.scrollUntilVisible(
      row,
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await frames(tester);
    expect(find.byType(CupertinoSwitch), findsNothing);
    expect(toggle, findsOneWidget);
    expect(store.skipOpLongPress, isTrue);
    expect(find.text(store.t('playback')), findsOneWidget);
    expect(find.text(store.t('skipOpLongPress')), findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(CupertinoIcons.forward_end),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.text(store.t('skipOpLongPressHint')),
      ),
      findsNothing,
    );
    final footer = find.text(store.t('skipOpLongPressHint'));
    await tester.scrollUntilVisible(
      footer,
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await frames(tester);
    expect(footer, findsOneWidget);

    await tester.tap(row);
    await frames(tester);
    expect(store.skipOpLongPress, isFalse);
    expect(
      (store.storage as MemoryStorage).values['baha.device.skipOpLongPress'],
      '0',
    );

    await tester.tap(toggle);
    await frames(tester);
    expect(store.skipOpLongPress, isTrue);
    expect(
      (store.storage as MemoryStorage).values['baha.device.skipOpLongPress'],
      '1',
    );

    await tester.tap(toggle);
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

  testWidgets('skipping age confirmation requires an explicit opt-in', (
    tester,
  ) async {
    final store = await launch(tester);
    await openAccount(tester);
    final row = find.byKey(
      const ValueKey('account-skip-age-confirmation-switch'),
    );
    final dialog = find.byType(GlassAlert);
    const key = 'baha.device.skipAgeConfirmation';
    await tester.scrollUntilVisible(
      row,
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await frames(tester);
    expect(store.skipAgeConfirmation, isFalse);

    await tester.tap(row);
    await frames(tester);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(dialog, findsOneWidget);
    expect(find.text('请确认阁下已年满18岁'), findsOneWidget);
    expect(
      find.textContaining('请不要将阁下之设备给予未满18岁之青少年使用'),
      findsOneWidget,
    );
    expect(store.skipAgeConfirmation, isFalse);
    await tester.tap(find.text(store.t('cancel')));
    await frames(tester);
    expect(store.skipAgeConfirmation, isFalse);
    expect(await store.storage.read(key), isNull);

    await tester.tap(row);
    await frames(tester);
    await tester.tap(find.text(store.t('skipAgeConfirmationEnable')));
    await frames(tester);
    expect(store.skipAgeConfirmation, isTrue);
    expect(await store.storage.read(key), '1');

    final restored = (await tester.runAsync(
      () => AppStore.create(
        storage: store.storage,
        metadataApi: FakeMetadata(),
        animeSearch: FakeSearch(),
      ),
    ))!;
    addTearDown(restored.dispose);
    expect(restored.skipAgeConfirmation, isTrue);

    await tester.tap(row);
    await frames(tester);
    expect(dialog, findsNothing);
    expect(store.skipAgeConfirmation, isFalse);
    expect(await store.storage.read(key), '0');
  });

  testWidgets(
    'GlassSettingsRow right-aligns trailing value and chevron with rows without values',
    (tester) async {
      final store = await launch(tester);
      store.updates
        ..cancelCheck()
        ..currentVersion = '0.5.15';
      store
        ..accountSynced = true
        ..favorites = [
          for (var i = 1; i <= 30; i++)
            Anime(
              id: '$i',
              title: '測試動畫 $i',
              cover: 'https://p2.bahamut.com.tw/$i.jpg',
            ),
        ];
      await openAccount(tester);

      Finder rowByTitle(String title) => find.ancestor(
        of: find.text(title),
        matching: find.byType(GlassSettingsRow),
      );

      double chevronRight(String title) => tester
          .getRect(
            find.descendant(
              of: rowByTitle(title),
              matching: find.byIcon(CupertinoIcons.chevron_right),
            ),
          )
          .right;

      final notificationsTitle = store.t('notifications');
      final favoritesTitle = store.t('favorites');
      final checkUpdatesTitle = store.t('checkUpdates');
      final diagnosticsTitle = store.t('diagnosticsTitle');

      expect(find.text('30'), findsOneWidget);
      final notificationsRight = chevronRight(notificationsTitle);
      final favoritesRight = chevronRight(favoritesTitle);
      expect(favoritesRight, closeTo(notificationsRight, 0.5));

      await tester.scrollUntilVisible(
        find.text(diagnosticsTitle),
        200,
        scrollable: find.descendant(
          of: find.byType(AccountPage),
          matching: find.byType(Scrollable),
        ),
      );
      await frames(tester);

      expect(find.text('0.5.15'), findsOneWidget);
      final checkUpdatesRight = chevronRight(checkUpdatesTitle);
      final diagnosticsRight = chevronRight(diagnosticsTitle);
      expect(checkUpdatesRight, closeTo(diagnosticsRight, 0.5));
      expect(checkUpdatesRight, closeTo(notificationsRight, 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'GlassSettingsRow keeps chevron right-aligned without overflow for long values on narrow viewports',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: SizedBox(
                width: 280,
                child: GlassSettingsGroup(
                  children: [
                    GlassSettingsRow(
                      key: const ValueKey('row-plain'),
                      title: '通知',
                      icon: CupertinoIcons.bell,
                      onTap: () {},
                    ),
                    GlassSettingsRow(
                      key: const ValueKey('row-short-value'),
                      title: '我的追番',
                      icon: CupertinoIcons.bookmark,
                      value: '30',
                      onTap: () {},
                    ),
                    GlassSettingsRow(
                      key: const ValueKey('row-long-value'),
                      title: '检查更新与非常长的标题',
                      icon: CupertinoIcons.arrow_clockwise,
                      value: '0.5.15-beta.20261128.very.long.version',
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      double chevronRight(String key) => tester
          .getRect(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byIcon(CupertinoIcons.chevron_right),
            ),
          )
          .right;

      final plainRight = chevronRight('row-plain');
      expect(chevronRight('row-short-value'), closeTo(plainRight, 0.5));
      expect(chevronRight('row-long-value'), closeTo(plainRight, 0.5));
      expect(tester.takeException(), isNull);
    },
  );
}
