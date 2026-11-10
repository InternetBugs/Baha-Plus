import 'dart:io';
import 'package:baha_plus/data/app_diagnostics.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/ui/account_page.dart';
import 'package:baha_plus/ui/diagnostics_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'core_test.dart' show MemoryStorage, FakeSearch;

void main() {
  Future<void> drain(WidgetTester tester) async {
    // File IO completes on the real event loop, while route/button animations
    // advance on the widget test's clock.
    for (var frame = 0; frame < 20; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(AppStore, List<(String, Rect)>)> launch(
    WidgetTester tester, {
    String language = 'zh-Hans',
    bool shareFails = false,
    Size size = const Size(400, 1000),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
    addTearDown(tester.view.reset);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('baha-diagnostics-ui-'),
    ))!;
    final shared = <(String, Rect)>[];
    final diagnostics = AppDiagnostics(
      directoryLoader: () async => directory,
      metadataLoader: () async => {'appVersion': '0.3.0', 'buildNumber': '4'},
      shareFile: (file, origin) async {
        if (shareFails) throw PlatformException(code: 'share-failed');
        shared.add((await file.readAsString(), origin));
      },
    );
    final store = (await tester.runAsync(() async {
      await diagnostics.initialize();
      return AppStore.create(
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
        diagnostics: diagnostics,
      );
    }))!;
    await store.setLanguage(language);
    addTearDown(() async {
      await drain(tester);
      store.dispose();
      diagnostics.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'BahaSans', brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: AccountPage(store: store, onCheckUpdates: () {}),
        ),
      ),
    );
    await drain(tester);
    await tester.scrollUntilVisible(
      find.text(store.t('diagnosticsTitle')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await drain(tester);
    await tester.tap(find.text(store.t('diagnosticsTitle')));
    await drain(tester);
    return (store, shared);
  }

  Future<void> tap(WidgetTester tester, AppStore store, String key) async {
    await tester.scrollUntilVisible(
      find.text(store.t(key)),
      160,
      scrollable: find
          .descendant(
            of: find.byType(DiagnosticsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await drain(tester);
    await Scrollable.ensureVisible(
      tester.element(find.text(store.t(key))),
      alignment: .5,
    );
    await drain(tester);
    await tester.tap(find.text(store.t(key)));
    await drain(tester);
  }

  for (final compact in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets('capture controls stay below navigation and visible '
          '(compact: $compact, ${brightness.name})', (tester) async {
        final size = compact ? const Size(320, 640) : const Size(400, 900);
        final (store, _) = await launch(
          tester,
          language: brightness == Brightness.light ? 'zh-Hans' : 'zh-Hant',
          size: size,
          textScale: compact ? 1.5 : 1,
          brightness: brightness,
        );
        final appBar = tester.getRect(find.byType(GlassAppBar));
        final status = tester.getRect(find.text(store.t('diagnosticsStopped')));
        expect(status.top, greaterThan(appBar.bottom));
        final start = find.text(store.t('diagnosticsStart'));
        expect(start.hitTestable(), findsOneWidget);
        final button = tester.getRect(
          find.ancestor(of: start, matching: find.byType(GlassButton)),
        );
        expect(button.top, greaterThan(appBar.bottom));
        expect(button.bottom, lessThan(size.height - 24));
        expect(button.width, greaterThan(size.width * .6));
        await tester.tap(start);
        await drain(tester);
        expect(store.diagnostics.enabled, isTrue);
        final stop = find.text(store.t('diagnosticsStop'));
        expect(stop.hitTestable(), findsOneWidget);
        await tester.tap(stop);
        await drain(tester);
        expect(store.diagnostics.enabled, isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final language in ['zh-Hans', 'zh-Hant']) {
    testWidgets('guest can record, stop, share and preview logs ($language)', (
      tester,
    ) async {
      final (store, shared) = await launch(tester, language: language);
      expect(store.hasAccount, isFalse);
      expect(find.byType(DiagnosticsPage), findsOneWidget);
      expect(find.text(store.t('diagnosticsStopped')), findsOneWidget);
      await tap(tester, store, 'diagnosticsStart');
      expect(store.diagnostics.enabled, isTrue);
      expect(find.text(store.t('diagnosticsRecording')), findsOneWidget);
      store.selectTab(2);
      await tap(tester, store, 'diagnosticsStop');
      expect(store.diagnostics.enabled, isFalse);
      await tap(tester, store, 'diagnosticsShare');
      expect(shared, hasLength(1));
      expect(shared.single.$1, contains('capture.started'));
      expect(shared.single.$1, contains('capture.stopped'));
      expect(shared.single.$1, contains('"event":"app.tab"'));
      expect(shared.single.$1, contains('"appVersion":"0.3.0"'));
      expect(shared.single.$2.width, greaterThan(0));
      expect(shared.single.$2.height, greaterThan(0));
      await tap(tester, store, 'diagnosticsPreview');
      final reportHeading = find.text('Baha Plus diagnostic report (v1)');
      expect(reportHeading, findsOneWidget);
      final previewAppBar = find.descendant(
        of: find.ancestor(
          of: reportHeading,
          matching: find.byType(GlassScaffold),
        ),
        matching: find.byType(GlassAppBar),
      );
      expect(
        tester.getRect(reportHeading).top,
        greaterThan(tester.getRect(previewAppBar).bottom),
      );
      await tester.tap(find.byIcon(CupertinoIcons.back).last);
      await drain(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'sharing failure offers copying and clear requires confirmation',
    (tester) async {
      final (store, shared) = await launch(tester, shareFails: true);
      await tap(tester, store, 'diagnosticsStart');
      await tap(tester, store, 'diagnosticsStop');
      await tap(tester, store, 'diagnosticsShare');
      expect(find.text(store.t('diagnosticsShareFailed')), findsOneWidget);
      expect(shared, isEmpty);
      await tester.tap(find.text(store.t('close')).last);
      await drain(tester);

      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tap(tester, store, 'diagnosticsCopy');
      expect(clipboard, contains('capture.started'));
      expect(find.text(store.t('diagnosticsCopied')), findsOneWidget);
      await tester.tap(find.text(store.t('close')).last);
      await drain(tester);
      await tap(tester, store, 'diagnosticsClear');
      expect(store.diagnostics.hasLogs, isTrue);
      await tester.tap(
        find.descendant(
          of: find.byType(CupertinoDialogAction),
          matching: find.text(store.t('diagnosticsClear')),
        ),
      );
      await drain(tester);
      expect(store.diagnostics.hasLogs, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
