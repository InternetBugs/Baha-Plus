import 'dart:async';
import 'dart:convert';
import 'package:baha_plus/data/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

http.Response releaseResponse(
  String version, {
  String? notes = '修复播放问题，改善观看体验。',
  bool draft = false,
  bool prerelease = false,
}) => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'tag_name': version,
      'body': notes,
      'draft': draft,
      'prerelease': prerelease,
    }),
  ),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final entry in [
    ('0.5.0', 'v0.5.1', true),
    ('0.5.9', 'v0.5.10', true),
    ('0.9.0', 'v0.10.0', true),
    ('0.5.0', '1.0.0', true),
    ('0.5.0', 'v0.5.0', false),
    ('0.6.0', 'v0.5.0', false),
    ('0.5.0+4', 'v0.5.0+5', false),
    ('0.5.0-rc.1+4', 'v0.5.0', true),
    ('0.6.0-rc.1', 'v0.5.0', false),
  ]) {
    test('installed ${entry.$1} against ${entry.$2}', () async {
      final updates = AppUpdates(
        versionLoader: () async => entry.$1,
        client: MockClient((request) async {
          expect(request.url, AppUpdates.latestReleaseUri);
          expect(request.headers['Accept'], 'application/vnd.github+json');
          return releaseResponse(entry.$2);
        }),
      );
      addTearDown(updates.dispose);
      expect(await updates.check(), entry.$3 ? isNotNull : isNull);
      expect(updates.currentVersion, entry.$1);
      expect(updates.checking, isFalse);
    });
  }

  test('reads the actual installed package version and UTF-8 notes', () async {
    PackageInfo.setMockInitialValues(
      appName: 'Baha Plus',
      packageName: 'app.bahaplus.mobile',
      version: '0.5.7',
      buildNumber: '5007',
      buildSignature: '',
    );
    final updates = AppUpdates(
      client: MockClient((_) async => releaseResponse('v0.5.8')),
    );
    addTearDown(updates.dispose);
    final release = await updates.check();
    expect(updates.currentVersion, '0.5.7');
    expect(release!.version.toString(), '0.5.8');
    expect(release.notes, '修复播放问题，改善观看体验。');
  });

  for (final response in [
    releaseResponse('v1.0.0', draft: true),
    releaseResponse('v1.0.0', prerelease: true),
    releaseResponse('v1.0.0-rc.1'),
    http.Response('', 404),
  ]) {
    test(
      'ignores unpublished, preview or missing releases: ${response.body}',
      () async {
        final updates = AppUpdates(
          versionLoader: () async => '0.5.0',
          client: MockClient((_) async => response),
        );
        addTearDown(updates.dispose);
        expect(await updates.check(), isNull);
      },
    );
  }

  for (final response in [
    http.Response('rate limited', 403),
    http.Response('rate limited', 429),
    http.Response('unavailable', 500),
    http.Response('invalid json', 200),
    releaseResponse('not-a-version'),
  ]) {
    test(
      'a failed check can be retried (${response.statusCode}, ${response.body})',
      () async {
        var requests = 0;
        final updates = AppUpdates(
          versionLoader: () async => '0.5.0',
          client: MockClient(
            (_) async => ++requests == 1 ? response : releaseResponse('v0.6.0'),
          ),
        );
        addTearDown(updates.dispose);
        await expectLater(updates.check(), throwsA(anything));
        expect(updates.checking, isFalse);
        expect(await updates.check(), isNotNull);
        expect(requests, 2);
      },
    );
  }

  test('startup runs once and simultaneous checks share one request', () async {
    final response = Completer<http.Response>();
    var requests = 0, versionReads = 0;
    final updates = AppUpdates(
      versionLoader: () async {
        versionReads++;
        return '0.5.0';
      },
      client: MockClient((_) {
        requests++;
        return response.future;
      }),
    );
    addTearDown(updates.dispose);
    final automatic = updates.check(automatic: true);
    final manual = updates.check();
    expect(manual, same(automatic));
    expect(updates.checking, isTrue);
    response.complete(releaseResponse('v0.6.0'));
    expect(await automatic, isNotNull);
    expect(await updates.check(automatic: true), isNull);
    expect(requests, 1);
    expect(versionReads, 1);
    expect(await updates.check(), isNotNull);
    expect(requests, 2);
    expect(versionReads, 1);
  });

  test('network timeout releases the checking state', () async {
    final response = Completer<http.Response>();
    final updates = AppUpdates(
      versionLoader: () async => '0.5.0',
      client: MockClient((_) => response.future),
      timeout: const Duration(milliseconds: 20),
    );
    addTearDown(updates.dispose);
    await expectLater(updates.check(), throwsA(isA<TimeoutException>()));
    expect(updates.checking, isFalse);
    response.complete(releaseResponse('v0.6.0'));
  });

  test('download opens exactly the repository Releases page', () async {
    final opened = <Uri>[];
    final updates = AppUpdates(
      openUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    addTearDown(updates.dispose);
    await updates.openDownloads();
    expect(
      opened.single.toString(),
      'https://github.com/InternetBugs/Baha-Plus/releases',
    );
  });

  test('a browser launch failure is reported to the caller', () async {
    final updates = AppUpdates(openUrl: (_) async => false);
    addTearDown(updates.dispose);
    await expectLater(updates.openDownloads(), throwsStateError);
  });

  test(
    'disposing during a check does not notify or return an update',
    () async {
      final version = Completer<String>();
      final updates = AppUpdates(
        versionLoader: () => version.future,
        client: MockClient((_) async => releaseResponse('v0.6.0')),
      );
      final pending = updates.check();
      updates.dispose();
      version.complete('0.5.0');
      expect(await pending, isNull);
    },
  );

  test('cancelling a version lookup permits a fresh manual check', () async {
    final version = Completer<String>();
    var reads = 0, requests = 0;
    final updates = AppUpdates(
      versionLoader: () =>
          ++reads == 1 ? version.future : Future.value('0.5.0'),
      client: MockClient((_) async {
        requests++;
        return releaseResponse('v0.6.0');
      }),
    );
    addTearDown(updates.dispose);
    final pending = updates.check();
    updates.cancelCheck();
    expect(await pending, isNull);
    expect(await updates.check(), isNotNull);
    version.complete('0.4.0');
    await Future<void>.delayed(Duration.zero);
    expect(updates.currentVersion, '0.5.0');
    expect(requests, 1);
  });

  group('AppRelease.extractChangelog', () {
    test('strips release_notes.py download section and outer heading', () {
      const body =
          '## 下载说明\r\n'
          '\r\n'
          '- Android：已签名的正式版 APK，按设备架构选择 `arm64-v8a`。\r\n'
          '- iOS：未签名的 IPA，安装前需签名。\r\n'
          '- SHA256SUMS.txt 包含校验值。\r\n'
          '\r\n'
          '## 更新内容\r\n'
          '\r\n'
          '### 播放改进\r\n'
          '\r\n'
          '- 修复暂停与播放恢复。\r\n';
      expect(
        AppRelease.extractChangelog(body),
        '### 播放改进\n\n- 修复暂停与播放恢复。',
      );
    });

    test('preserves sibling level-2 headings written inside update notes', () {
      const body =
          '## 下载说明\n'
          '- Android APK\n'
          '\n'
          '## 更新内容\n'
          '\n'
          '## 新功能\n'
          '- 画中画\n'
          '\n'
          '## 问题修复\n'
          '- 修复卡顿\n';
      expect(
        AppRelease.extractChangelog(body),
        '## 新功能\n- 画中画\n\n## 问题修复\n- 修复卡顿',
      );
    });

    test('strips trailing install section and its subsections', () {
      const body =
          '## 更新內容\n'
          '- 新增 iOS 26 液態玻璃更新彈窗\n'
          '\n'
          '## 安裝說明\n'
          '### Android\n'
          '下載對應架構的 APK。\n'
          '### iOS\n'
          '透過 AltStore 簽名安裝。\n';
      expect(AppRelease.extractChangelog(body), '- 新增 iOS 26 液態玻璃更新彈窗');
    });

    test('returns empty string when only download instructions exist', () {
      const body =
          '## 下载说明\n'
          '- Android：APK\n'
          '- iOS：IPA\n'
          '\n'
          '## 更新内容\n'
          '   \n';
      expect(AppRelease.extractChangelog(body), isEmpty);
    });

    test('preserves plain text notes and fenced code blocks untouched', () {
      expect(
        AppRelease.extractChangelog('新增检查更新功能。\n修复播放器卡顿。'),
        '新增检查更新功能。\n修复播放器卡顿。',
      );
      const fenced = '```sh\n## 下载说明\necho ok\n```';
      expect(AppRelease.extractChangelog(fenced), fenced);
    });
  });
}
