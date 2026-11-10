import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:baha_plus/data/app_diagnostics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDiagnostics diagnostics;

  AppDiagnostics create({DiagnosticShare? shareFile}) => AppDiagnostics(
    directoryLoader: () async => root,
    metadataLoader: () async => {
      'appVersion': '0.3.0',
      'buildNumber': '4',
      'platform': 'test',
    },
    shareFile: shareFile,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('baha-diagnostics-');
    diagnostics = create();
  });

  tearDown(() async {
    try {
      await diagnostics.flush();
    } catch (_) {}
    diagnostics.dispose();
    await root.delete(recursive: true);
  });

  test(
    'opt in, stop, export metadata and do not collect while disabled',
    () async {
      await diagnostics.initialize();
      expect(diagnostics.enabled, isFalse);
      expect(diagnostics.hasLogs, isFalse);
      diagnostics.record('before-consent');
      await diagnostics.start();
      diagnostics.record('reproduction', {'position': 42});
      await diagnostics.stop();
      diagnostics.record('after-stop');
      final report = await (await diagnostics.export()).readAsString();
      expect(report, contains('"appVersion":"0.3.0"'));
      expect(report, contains('"buildNumber":"4"'));
      expect(report, contains('capture.started'));
      expect(report, contains('"event":"reproduction"'));
      expect(report, contains('capture.stopped'));
      expect(report, isNot(contains('before-consent')));
      expect(report, isNot(contains('after-stop')));
      expect(diagnostics.hasLogs, isTrue);
    },
  );

  test(
    'recording and previous events survive restart, stopped state persists',
    () async {
      await diagnostics.start();
      diagnostics.record('before-restart');
      await diagnostics.flush();
      final restarted = create();
      try {
        await restarted.initialize();
        expect(restarted.enabled, isTrue);
        final text = await (await restarted.export()).readAsString();
        expect(text, contains('before-restart'));
        expect(text, contains('capture.resumed'));
        await restarted.stop();
        final stopped = create();
        try {
          await stopped.initialize();
          expect(stopped.enabled, isFalse);
          expect(stopped.hasLogs, isTrue);
        } finally {
          stopped.dispose();
        }
      } finally {
        restarted.dispose();
      }
    },
  );

  test(
    'redacts secrets, URLs, local paths and emails before writing',
    () async {
      await diagnostics.start();
      diagnostics.record('redaction', {
        'cookie': 'secret-cookie',
        'nested': {'authToken': 'secret-token', 'password': 'secret-password'},
        'sourceUrl': 'https://example.com/?token=secret-media',
        'detail': 'https://example.com/private?key=secret-value',
        'path': r'C:\Users\private-user\private-file.dart:12',
        'contact': 'person@example.com',
        'position': 125.5,
        'buffering': false,
      });
      diagnostics.recordError(
        'native.error',
        PlatformException(
          code: 'decoder-failed',
          message: 'Cookie: super-private; https://example.com/signed',
          details: {'cookie': 'even-more-private'},
        ),
        StackTrace.fromString(
          '#0 Player.play (package:baha_plus/player.dart:12:3)',
        ),
      );
      final report = await (await diagnostics.export()).readAsString();
      final disk = await File(
        '${root.path}/diagnostics/current.jsonl',
      ).readAsString();
      for (final content in [report, disk]) {
        for (final value in [
          'secret-cookie',
          'secret-token',
          'secret-password',
          'secret-media',
          'secret-value',
          'private-user',
          'private-file',
          'person@example.com',
          'super-private',
          'even-more-private',
          'https://example.com',
        ]) {
          expect(content, isNot(contains(value)), reason: value);
        }
        expect(content, contains('"position":125.5'));
        expect(content, contains('"buffering":false'));
        expect(content, contains('decoder-failed'));
        expect(content, contains('package:baha_plus/player.dart:12:3'));
      }
    },
  );

  test(
    'rotates bounded journals and exports the newest events in order',
    () async {
      await diagnostics.start();
      final payload = List.filled(1700, 'a').join();
      for (var index = 0; index < 760; index++) {
        diagnostics.record('sample.$index', {'metric': payload});
        if (index % 24 == 0) await diagnostics.flush();
      }
      await diagnostics.stop();
      for (final name in ['current', 'previous']) {
        final file = File('${root.path}/diagnostics/$name.jsonl');
        expect(await file.exists(), isTrue);
        expect(
          await file.length(),
          lessThanOrEqualTo(AppDiagnostics.maxFileBytes),
        );
      }
      final report = await (await diagnostics.export()).readAsString();
      expect(
        utf8.encode(report).length,
        lessThan(2 * AppDiagnostics.maxFileBytes + 4096),
      );
      expect(report, isNot(contains('"event":"sample.0"')));
      expect(report, contains('"event":"sample.759"'));
      final events = report
          .split('--- Events (UTC, oldest first) ---\n')
          .last
          .trim()
          .split('\n')
          .map((e) => jsonDecode(e) as Map)
          .toList();
      final times = events.map((e) => e['time'] as String).toList();
      expect(times, orderedEquals([...times]..sort()));
    },
  );

  test('oversize and non-finite input remains bounded valid JSON', () async {
    await diagnostics.start();
    diagnostics.record('large', {
      for (var index = 0; index < 48; index++)
        'key$index': List.filled(4000, '中').join(),
    });
    diagnostics.record('non-finite', {'value': double.infinity});
    await diagnostics.stop();
    final lines = await File(
      '${root.path}/diagnostics/current.jsonl',
    ).readAsLines();
    for (final line in lines) {
      expect(
        utf8.encode(line).length,
        lessThanOrEqualTo(AppDiagnostics.maxEntryBytes),
      );
      expect(jsonDecode(line), isA<Map>());
    }
    expect(lines.join(), contains('"truncated":true'));
    expect(lines.join(), contains('"value":null'));
  });

  test(
    'clear removes journals and exported copies while keeping opt-in',
    () async {
      await diagnostics.start();
      diagnostics.record('old-private-session');
      final report = await diagnostics.export();
      expect(await report.exists(), isTrue);
      await diagnostics.clear();
      expect(diagnostics.enabled, isTrue);
      expect(await report.exists(), isFalse);
      final text = await (await diagnostics.export()).readAsString();
      expect(text, isNot(contains('old-private-session')));
      expect(text, contains('capture.cleared'));
      await diagnostics.stop();
      await diagnostics.clear();
      expect(diagnostics.enabled, isFalse);
      expect(diagnostics.hasLogs, isFalse);
    },
  );

  test(
    'report retention is bounded and share receives a real text file and anchor',
    () async {
      final shared = <File>[];
      final sharing = create(
        shareFile: (file, origin) async {
          expect(origin, const Rect.fromLTWH(10, 10, 150, 48));
          expect(await file.exists(), isTrue);
          expect(
            await file.readAsString(),
            contains('Baha Plus diagnostic report'),
          );
          shared.add(file);
        },
      );
      try {
        await sharing.start();
        File? report;
        for (var index = 0; index < 5; index++) {
          report = await sharing.export();
        }
        await sharing.share(report!, const Rect.fromLTWH(10, 10, 150, 48));
        expect(shared.single.path, endsWith('.txt'));
        final files = await Directory(
          '${root.path}/diagnostics/exports',
        ).list().toList();
        expect(files, hasLength(3));
        await sharing.stop();
      } finally {
        sharing.dispose();
      }
    },
  );

  test('initialization can retry and write failures are surfaced', () async {
    var attempts = 0;
    final retrying = AppDiagnostics(
      directoryLoader: () async {
        if (attempts++ == 0) throw const FileSystemException('Unavailable');
        return root;
      },
    );
    try {
      await expectLater(
        retrying.initialize(),
        throwsA(isA<FileSystemException>()),
      );
      await retrying.initialize();
      await Directory('${root.path}/diagnostics/current.jsonl').create();
      await expectLater(retrying.start(), throwsA(isA<FileSystemException>()));
      expect(retrying.writeFailed, isTrue);
      await Directory('${root.path}/diagnostics/current.jsonl').delete();
      await retrying.clear();
      await retrying.flush();
      expect(retrying.writeFailed, isFalse);
      await retrying.stop();
    } finally {
      retrying.dispose();
    }
  });

  test(
    'Flutter and uncaught error hooks preserve existing handler behavior',
    () async {
      await diagnostics.start();
      final oldFlutter = FlutterError.onError;
      final oldPlatform = PlatformDispatcher.instance.onError;
      var flutterCalled = false, platformCalled = false;
      FlutterError.onError = (_) => flutterCalled = true;
      PlatformDispatcher.instance.onError = (_, _) {
        platformCalled = true;
        return false;
      };
      try {
        diagnostics.installErrorHooks();
        FlutterError.onError!(
          FlutterErrorDetails(exception: StateError('private')),
        );
        final handled = PlatformDispatcher.instance.onError!(
          StateError('private'),
          StackTrace.fromString('package:baha_plus/main.dart:42'),
        );
        expect(flutterCalled, isTrue);
        expect(platformCalled, isTrue);
        expect(handled, isFalse);
      } finally {
        FlutterError.onError = oldFlutter;
        PlatformDispatcher.instance.onError = oldPlatform;
      }
      final report = await (await diagnostics.export()).readAsString();
      expect(report, contains('flutter.error'));
      expect(report, contains('dart.error'));
      expect(report, isNot(contains('private')));
    },
  );
}
