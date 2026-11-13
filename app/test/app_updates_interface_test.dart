import 'fake_metadata.dart';
import 'dart:async';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/app_updates.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/account_page.dart';
import 'package:baha_plus/ui/chrome.dart';
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
        metadataApi: FakeMetadata(),
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
        updates: updates,
      ),
    ))!;
    addTearDown(store.dispose);
    await store.setLanguage('zh-Hans');
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: BahaPlusApp(store: store, mountPortal: false),
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
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('当前版本：0.5.0\n最新版本：0.6.0'), findsOneWidget);
      expect(find.text('更新内容'), findsOneWidget);
      expect(find.text('新增检查更新功能。\n修复播放器卡顿。'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.text(store.t('downloadUpdate')));
      await frames(tester);
      expect(opened, [AppUpdates.downloadsUri]);
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
}
