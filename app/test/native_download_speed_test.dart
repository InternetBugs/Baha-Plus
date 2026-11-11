import 'dart:async';
import 'package:baha_plus/data/native_download_speed.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'native_playback_test.dart' show FakeVideo, sourceJson;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.bahaplus.mobile/playback_download');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeDownloadSpeed monitor;
  late List<double> speeds;
  late List<String> calls;
  late int time, bytes, source;
  Completer<Map<String, int>?>? pending;

  setUp(() {
    time = bytes = source = 0;
    speeds = [];
    calls = [];
    pending = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'start' => true,
        'sample' => pending?.future ?? {'bytes': bytes, 'source': source},
        _ => null,
      };
    });
    monitor = NativeDownloadSpeed(
      onSpeed: speeds.add,
      elapsedMicroseconds: () => time,
    );
  });

  tearDown(() {
    monitor.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> start() async {
    monitor.setEnabled(true);
    await monitor.start('current', [
      'https://bahamut.akamaized.net/master.m3u8',
    ]);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'transfer deltas use elapsed time and decay to zero when idle',
    () async {
      await start();
      expect(speeds.last, 0);
      bytes = 512 * 1024;
      time = 1000000;
      await monitor.sample();
      expect(speeds.last, 512 * 1024);
      bytes += 2 * 1024 * 1024;
      time += 2000000;
      await monitor.sample();
      expect(speeds.last, 1024 * 1024);
      time += 1000000;
      await monitor.sample();
      expect(speeds.last, 0);
    },
  );

  test(
    'source replacements and counter resets establish new baselines',
    () async {
      await start();
      bytes = 1000;
      time = 1000000;
      await monitor.sample();
      expect(speeds.last, 1000);
      source++;
      bytes = 500000;
      time += 1000000;
      await monitor.sample();
      expect(speeds.last, 0);
      bytes += 2000;
      time += 1000000;
      await monitor.sample();
      expect(speeds.last, 2000);
      bytes = 10;
      time += 1000000;
      await monitor.sample();
      expect(speeds.last, 0);
    },
  );

  test(
    'hidden indicators stop polling and resume with a fresh baseline',
    () async {
      await start();
      monitor.setEnabled(false);
      final count = calls.length;
      time += 10000000;
      bytes += 10000000;
      await monitor.sample();
      expect(calls, hasLength(count));
      monitor.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(speeds.last, 0);
      time += 1000000;
      bytes += 1000;
      await monitor.sample();
      expect(speeds.last, 1000);
    },
  );

  test('late samples cannot publish after disabling or disposal', () async {
    await start();
    pending = Completer<Map<String, int>?>();
    final reading = monitor.sample();
    monitor.setEnabled(false);
    final count = speeds.length;
    pending!.complete({'bytes': 100000, 'source': 0});
    await reading;
    expect(speeds, hasLength(count));
    pending = Completer<Map<String, int>?>();
    monitor.setEnabled(true);
    monitor.dispose();
    pending!.complete({'bytes': 200000, 'source': 0});
    await Future<void>.delayed(Duration.zero);
    expect(speeds, hasLength(count));
  });

  test('unavailable native statistics do not start polling', () async {
    messenger.setMockMethodCallHandler(channel, null);
    await start();
    expect(speeds, isEmpty);
  });

  testWidgets(
    'native loading publishes speed before handoff and stops when ready',
    (tester) async {
      final previousPlatform = VideoPlayerPlatform.instance;
      final platform = FakeVideo()..holdCreation = Completer<void>();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previousPlatform);
      final states = <PlaybackState>[];
      final native = NativePlayback(
        document: 'current',
        source: NativePlaybackSource.fromJson(sourceJson()),
        userAgent: 'device agent',
        onState: states.add,
      );
      try {
        final initialization = native.initialize(0);
        await tester.pump();
        expect(states.last.phase, PlaybackPhase.loading);
        expect(states.last.downloadBytesPerSecond, 0);
        bytes = 1024 * 1024;
        await tester.pump(const Duration(seconds: 1));
        expect(states.last.phase, PlaybackPhase.loading);
        expect(states.last.downloadBytesPerSecond, greaterThan(0));
        platform.holdCreation!.complete();
        await tester.pump();
        await initialization;
        await native.activate(
          applicationActive: true,
          timeline: {'position': 10, 'paused': true, 'rate': 1, 'muted': false},
        );
        expect(states.last.buffering, isFalse);
        expect(states.last.downloadBytesPerSecond, 0);
        final sampleCount = calls.where((call) => call == 'sample').length;
        await tester.pump(const Duration(seconds: 2));
        expect(calls.where((call) => call == 'sample'), hasLength(sampleCount));

        platform.streams.values.single.add(
          VideoEvent(eventType: VideoEventType.bufferingStart),
        );
        await tester.pump();
        bytes += 2048;
        await tester.pump(const Duration(seconds: 1));
        expect(states.last.buffering, isTrue);
        expect(states.last.downloadBytesPerSecond, greaterThan(0));
        await native.setApplicationActive(false);
        final backgroundSamples = calls
            .where((call) => call == 'sample')
            .length;
        await tester.pump(const Duration(seconds: 2));
        expect(
          calls.where((call) => call == 'sample'),
          hasLength(backgroundSamples),
        );
      } finally {
        await tester.runAsync(() async {
          native.dispose();
          await native.released;
        });
      }
    },
  );
}
