import 'fake_playback.dart';
import 'fake_metadata.dart';
import 'dart:async';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/app_updates.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/account_page.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/update_dialog.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'app_updates_test.dart' show releaseResponse;
import 'core_test.dart' show MemoryStorage, FakeSearch;

void main() {
  Future<void> frames(WidgetTester tester) async {
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(AppStore, List<Uri>, List<Uri>)> launch(
    WidgetTester tester, {
    required Future<http.Response> Function(http.Request) response,
    bool browserOpens = true,
    Size size = const Size(400, 850),
    double textScale = 1,
    String appearance = 'light',
    String glassStyle = 'standard',
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <Uri>[], opened = <Uri>[];
    final updates = AppUpdates(
      versionLoader: () async => '0.5.0',
      client: MockClient((request) {
        requests.add(request.url);
        return response(request);
      }),
      openUrl: (uri) async {
        opened.add(uri);
        return browserOpens;
      },
    );
    final store = (await tester.runAsync(
      () => AppStore.create(
        nativeHttpApiFactory: PendingNativeHttpApi.new,
        metadataApi: FakeMetadata(),
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
        updates: updates,
      ),
    ))!;
    addTearDown(store.dispose);
    await store.setLanguage('zh-Hans');
    await store.setAppearance(appearance);
    await store.setGlassStyle(glassStyle);
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
          ),
          child: BahaPlusApp(store: store, mountPortal: false),
        ),
      ),
    );
    await frames(tester);
    return (store, requests, opened);
  }

  Future<void> account(WidgetTester tester, String target) async {
    await tester.tap(find.byType(AccountAvatar).hitTestable());
    await frames(tester);
    await tester.scrollUntilVisible(
      find.text(target),
      150,
      scrollable: find.descendant(
        of: find.byType(AccountPage),
        matching: find.byType(Scrollable),
      ),
    );
    await frames(tester);
  }

  testWidgets(
    'startup shows the new version and notes, download opens Releases',
    (tester) async {
      final (store, requests, opened) = await launch(
        tester,
        response: (_) async =>
            releaseResponse('v0.6.0', notes: '新增检查更新功能。\n修复播放器卡顿。'),
      );
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.byType(GlassUpdateAlert), findsOneWidget);
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('当前版本：0.5.0\n最新版本：0.6.0'), findsOneWidget);
      expect(find.text('更新内容'), findsOneWidget);
      expect(find.text('新增检查更新功能。\n修复播放器卡顿。'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.text(store.t('downloadUpdate')));
      await frames(tester);
      expect(opened, [AppUpdates.downloadsUri]);
      expect(find.byType(GlassUpdateAlert), findsNothing);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      store.selectTab(2);
      await frames(tester);
      expect(requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'later dismisses the update without opening a browser or prompting again',
    (tester) async {
      final (store, requests, opened) = await launch(
        tester,
        response: (_) async => releaseResponse('v0.6.0'),
      );
      await tester.tap(find.text('稍后再说'));
      await frames(tester);
      store.selectTab(4);
      await frames(tester);
      store.selectTab(0);
      await frames(tester);
      expect(opened, isEmpty);
      expect(requests, hasLength(1));
      expect(find.byType(GlassUpdateAlert), findsNothing);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
    },
  );

  for (final response in [
    releaseResponse('v0.5.0'),
    releaseResponse('v0.4.0'),
    http.Response('', 404),
    http.Response('rate limited', 403),
    http.Response('rate limited', 429),
    http.Response('unavailable', 500),
    http.Response('invalid json', 200),
  ]) {
    testWidgets(
      'startup remains silent (${response.statusCode}, ${response.body})',
      (tester) async {
        final (_, requests, opened) = await launch(
          tester,
          response: (_) async => response,
        );
        expect(requests, hasLength(1));
        expect(find.byType(GlassUpdateAlert), findsNothing);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(find.text('无可用更新'), findsNothing);
        expect(find.text('暂时无法检查更新，请稍后重试。'), findsNothing);
        expect(opened, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('manual check reports exactly no available updates', (
    tester,
  ) async {
    final (_, requests, opened) = await launch(
      tester,
      response: (_) async => releaseResponse('v0.5.0'),
    );
    await account(tester, '检查更新');
    expect(find.text('0.5.0'), findsOneWidget);
    await tester.tap(find.text('检查更新'));
    await frames(tester);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('update-message-dialog')), findsOneWidget);
    expect(find.text('无可用更新'), findsOneWidget);
    expect(requests, hasLength(2));
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'clicking the installed version shows notes and prevents duplicate checks',
    (tester) async {
      var calls = 0;
      final pending = Completer<http.Response>();
      final (_, requests, opened) = await launch(
        tester,
        response: (_) => ++calls == 1
            ? Future.value(releaseResponse('v0.5.0'))
            : pending.future,
      );
      await account(tester, '检查更新');
      await tester.tap(find.text('0.5.0'));
      await frames(tester);
      expect(find.text('正在检查更新…'), findsOneWidget);
      await tester.tap(find.text('0.5.0'));
      await frames(tester);
      expect(requests, hasLength(2));
      pending.complete(releaseResponse('v0.6.0', notes: '这是新版本的更新内容。'));
      await frames(tester);
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('这是新版本的更新内容。'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.text('前往下载'));
      await frames(tester);
      expect(opened, [AppUpdates.downloadsUri]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manual check shows a failure and allows another attempt', (
    tester,
  ) async {
    final (_, requests, _) = await launch(
      tester,
      response: (_) async => http.Response('', 500),
    );
    await account(tester, '检查更新');
    await tester.tap(find.text('检查更新'));
    await frames(tester);
    expect(find.text('暂时无法检查更新，请稍后重试。'), findsOneWidget);
    await tester.tap(find.text('关闭').last);
    await frames(tester);
    await tester.tap(find.text('检查更新'));
    await frames(tester);
    expect(requests, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long release notes scroll while download remains accessible', (
    tester,
  ) async {
    final (_, _, opened) = await launch(
      tester,
      size: const Size(568, 320),
      response: (_) async => releaseResponse(
        'v0.6.0',
        notes: List.generate(
          80,
          (index) => '第 ${index + 1} 项更新：改善使用体验。',
        ).join('\n'),
      ),
    );
    expect(find.text('前往下载').hitTestable(), findsOneWidget);
    expect(find.text('稍后再说').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('前往下载'));
    await frames(tester);
    expect(opened, [AppUpdates.downloadsUri]);
  });

  testWidgets(
    'missing notes have a readable fallback and browser failure is actionable',
    (tester) async {
      await launch(
        tester,
        browserOpens: false,
        response: (_) async => releaseResponse('v0.6.0', notes: null),
      );
      expect(find.text('此版本未提供更新说明。'), findsOneWidget);
      await tester.tap(find.text('前往下载'));
      await frames(tester);
      expect(find.text('暂时无法打开下载页面，请稍后重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dialog strips download instructions and formats Markdown release notes cleanly',
    (tester) async {
      await launch(
        tester,
        response: (_) async => releaseResponse(
          'v0.6.0',
          notes:
              '## 下载说明\n\n'
              '- Android：已签名的正式版 APK。\n'
              '- iOS：未签名的 IPA，安装前需签名。\n\n'
              '## 更新内容\n\n'
              '### 画中画\n'
              '- 播放页新增 **画中画** 按钮，支持 `iOS` 与 [Android](https://example.com) 小窗\n'
              '- 修复 \\[播放器\\] 偶发卡顿\n\n'
              '### 平板与宽屏\n'
              '1. 宽度 ≥900pt 切换左侧导航栏\n',
        ),
      );
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('更新内容'), findsOneWidget);
      expect(find.text('画中画'), findsOneWidget);
      expect(find.text('平板与宽屏'), findsOneWidget);
      expect(
        find.text('播放页新增 画中画 按钮，支持 iOS 与 Android 小窗'),
        findsOneWidget,
      );
      expect(find.text('修复 [播放器] 偶发卡顿'), findsOneWidget);
      expect(find.text('宽度 ≥900pt 切换左侧导航栏'), findsOneWidget);
      expect(find.textContaining('###'), findsNothing);
      expect(find.textContaining('**'), findsNothing);
      expect(find.textContaining('https://example.com'), findsNothing);
      expect(find.textContaining('下载说明'), findsNothing);
      expect(find.textContaining('未签名的 IPA'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dialog falls back when release body only contains download instructions',
    (tester) async {
      await launch(
        tester,
        response: (_) async => releaseResponse(
          'v0.6.0',
          notes: '## 安装说明\n\n- 下载对应平台的安装包。\n',
        ),
      );
      expect(find.text('此版本未提供更新说明。'), findsOneWidget);
      expect(find.textContaining('安装说明'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a startup response after the app is removed never opens a dialog',
    (tester) async {
      final pending = Completer<http.Response>();
      final (_, _, opened) = await launch(
        tester,
        response: (_) => pending.future,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete(releaseResponse('v0.6.0'));
      await frames(tester);
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'update dialog uses iOS 26 Liquid Glass geometry, left-aligned layout, and side-by-side pills',
    (tester) async {
      await launch(
        tester,
        response: (_) async =>
            releaseResponse('v0.6.0', notes: '改善播放稳定性与界面响应。'),
      );
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      final surface = tester.widget<GlassContainer>(
        find.byKey(const ValueKey('update-dialog-glass-surface')),
      );
      expect(surface.useOwnLayer, isTrue);
      expect(surface.shape, isA<LiquidRoundedSuperellipse>());
      expect(
        (surface.shape as LiquidRoundedSuperellipse).borderRadius,
        greaterThanOrEqualTo(34),
      );
      expect(find.byKey(const ValueKey('update-notes-well')), findsOneWidget);

      final titleLeft = tester.getTopLeft(find.text('发现新版本')).dx;
      final versionLeft = tester
          .getTopLeft(find.text('当前版本：0.5.0\n最新版本：0.6.0'))
          .dx;
      expect(versionLeft, closeTo(titleLeft, 0.5));

      final laterRect = tester.getRect(
        find.byKey(const ValueKey('update-later-action')),
      );
      final downloadRect = tester.getRect(
        find.byKey(const ValueKey('update-download-action')),
      );
      expect(laterRect.center.dy, closeTo(downloadRect.center.dy, 1));
      expect(downloadRect.left, greaterThan(laterRect.right));
      expect(laterRect.height, greaterThanOrEqualTo(44));
      expect(downloadRect.height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'update dialog stacks actions with primary CTA on top for large text and compact screens',
    (tester) async {
      final (_, _, opened) = await launch(
        tester,
        size: const Size(320, 640),
        textScale: 1.8,
        appearance: 'dark',
        disableAnimations: true,
        response: (_) async => releaseResponse(
          'v0.6.0',
          notes: List.generate(24, (i) => '更新项目 ${i + 1}').join('\n'),
        ),
      );
      final surfaceRect = tester.getRect(
        find.byKey(const ValueKey('update-dialog-glass-surface')),
      );
      expect(surfaceRect.left, greaterThanOrEqualTo(0));
      expect(surfaceRect.right, lessThanOrEqualTo(320));
      expect(surfaceRect.top, greaterThanOrEqualTo(0));
      expect(surfaceRect.bottom, lessThanOrEqualTo(640));

      final downloadRect = tester.getRect(
        find.byKey(const ValueKey('update-download-action')),
      );
      final laterRect = tester.getRect(
        find.byKey(const ValueKey('update-later-action')),
      );
      expect(downloadRect.bottom, lessThan(laterRect.top));
      expect(find.text('前往下载').hitTestable(), findsOneWidget);
      expect(find.text('稍后再说').hitTestable(), findsOneWidget);

      await tester.tap(find.text('前往下载'));
      await frames(tester);
      expect(opened, [AppUpdates.downloadsUri]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in {
    'performance': GlassQuality.minimal,
    'standard': GlassQuality.standard,
    'premium': GlassQuality.premium,
  }.entries) {
    testWidgets('update dialog honors ${entry.key} glass style tier', (
      tester,
    ) async {
      await launch(
        tester,
        glassStyle: entry.key,
        appearance: entry.key == 'premium' ? 'dark' : 'light',
        size: entry.key == 'premium'
            ? const Size(1024, 768)
            : const Size(400, 850),
        response: (_) async => releaseResponse('v0.6.0'),
      );
      final surface = tester.widget<GlassContainer>(
        find.byKey(const ValueKey('update-dialog-glass-surface')),
      );
      expect(surface.quality, entry.value);
      if (entry.key == 'premium') {
        final rect = tester.getRect(
          find.byKey(const ValueKey('update-dialog-glass-surface')),
        );
        expect(rect.width, lessThanOrEqualTo(392));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
