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
}
