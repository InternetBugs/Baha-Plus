import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/ui/native_video_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SurfacePlayback extends NativePlayback {
  SurfacePlayback({double position = 0, bool paused = false})
    : super(
        document: 'surface-test',
        source: NativePlaybackSource.fromJson({
          'master': 'https://bahamut.akamaized.net/master.m3u8',
          'variants': [],
          'position': 0,
          'duration': 1200,
          'rate': 1,
          'paused': true,
          'muted': false,
        }),
        userAgent: '',
        onState: (_) {},
      ) {
    _state = _value(position: position, paused: paused);
  }

  late PlaybackState _state;
  int _revision = 0;

  @override
  PlaybackState get state => _state;

  @override
  int get seekRevision => _revision;

  static PlaybackState _value({
    required double position,
    required bool paused,
    bool buffering = false,
    double rate = 1,
  }) => PlaybackState(
    phase: PlaybackPhase.content,
    surfaceReady: true,
    position: position,
    duration: 1200,
    paused: paused,
    buffering: buffering,
    rate: rate,
  );

  void sample(
    double position, {
    bool paused = false,
    bool buffering = false,
    double rate = 1,
    bool seek = false,
  }) {
    if (seek) _revision++;
    _state = _value(
      position: position,
      paused: paused,
      buffering: buffering,
      rate: rate,
    );
    notifyListeners();
  }
}

NativeDanmaku comment(String id, double time, {String mode = 'rolling'}) =>
    NativeDanmaku.fromJson({
      'id': id,
      'text': '弹幕 $id',
      'time': time,
      'mode': mode,
      'size': 18,
      'color': '#FFFFFF',
    });

Widget surface(
  SurfacePlayback playback,
  List<NativeDanmaku> items, {
  DanmakuSettings settings = const DanmakuSettings(),
}) => MaterialApp(
  home: NativeVideoSurface(
    playback: playback,
    danmaku: items,
    settings: settings,
    errorLabel: 'error',
    retryLabel: 'retry',
    onRetry: () {},
  ),
);

NativeVideoSurfaceState surfaceState(WidgetTester tester) =>
    tester.state<NativeVideoSurfaceState>(find.byType(NativeVideoSurface));

void main() {
  testWidgets('empty danmaku never requests animation frames during playback', (
    tester,
  ) async {
    final playback = SurfacePlayback(position: 1);
    await tester.pumpWidget(surface(playback, const []));
    final state = surfaceState(tester);
    expect(state.danmakuAnimationActive, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    final position = state.presentedDanmakuPosition;
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 250));
      playback.sample(1 + (index + 1) * .25);
      expect(state.danmakuAnimationActive, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      expect(state.presentedDanmakuPosition, position);
    }
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
  });

  testWidgets(
    'an empty interval wakes for the next message and sleeps after it',
    (tester) async {
      final playback = SurfacePlayback(position: 1);
      await tester.pumpWidget(surface(playback, [comment('1', 5)]));
      final state = surfaceState(tester);
      expect(state.danmakuAnimationActive, isFalse);
      expect(state.cachedTextPainters, 0);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 3990));
      expect(state.cachedTextPainters, 0);
      expect(state.danmakuAnimationActive, isFalse);

      await tester.pump(const Duration(milliseconds: 20));
      expect(state.danmakuAnimationActive, isTrue);
      expect(state.cachedTextPainters, 1);
      // The boundary was published at 5s, only 10ms before this frame.
      // Retain it until a full 60 FPS interval has elapsed.
      expect(state.presentedDanmakuPosition, 5);
      await tester.pump(const Duration(microseconds: 16667));
      expect(state.presentedDanmakuPosition, closeTo(5.026667, .000001));
      await tester.pump(const Duration(seconds: 10));
      expect(state.danmakuAnimationActive, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      expect(state.cachedTextPainters, 0);
      expect(state.cachedRasterBytes, 0);
      await tester.pumpWidget(const SizedBox());
      playback.dispose();
    },
  );

  testWidgets(
    'fixed messages repaint at boundaries without continuous frames',
    (tester) async {
      final playback = SurfacePlayback(position: 1);
      await tester.pumpWidget(
        surface(playback, [
          comment('1', 1, mode: 'top'),
          comment('2', 2, mode: 'bottom'),
        ]),
      );
      final state = surfaceState(tester);
      expect(state.cachedTextPainters, 1);
      expect(state.danmakuAnimationActive, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(state.cachedTextPainters, 2);
      expect(state.danmakuAnimationActive, isFalse);
      await tester.pump(const Duration(seconds: 4));
      expect(state.cachedTextPainters, 1);
      expect(state.danmakuAnimationActive, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(state.cachedTextPainters, 0);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      playback.dispose();
    },
  );

  testWidgets(
    'disabled modes do not animate and enabling them uses current time',
    (tester) async {
      final playback = SurfacePlayback(position: 1);
      final items = [comment('1', 3)];
      await tester.pumpWidget(
        surface(
          playback,
          items,
          settings: const DanmakuSettings(rolling: false),
        ),
      );
      final state = surfaceState(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(state.cachedTextPainters, 0);
      expect(state.danmakuAnimationActive, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(surface(playback, items));
      expect(state.presentedDanmakuPosition, closeTo(5, .00001));
      expect(state.cachedTextPainters, 1);
      expect(state.danmakuAnimationActive, isTrue);
      await tester.pumpWidget(
        surface(
          playback,
          items,
          settings: const DanmakuSettings(enabled: false),
        ),
      );
      expect(state.cachedTextPainters, 0);
      expect(state.danmakuAnimationActive, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      playback.dispose();
    },
  );

  testWidgets('120 Hz frames produce at most 60 rolling position updates', (
    tester,
  ) async {
    final playback = SurfacePlayback(position: 1);
    final items = [comment('1', 0)];
    await tester.pumpWidget(surface(playback, items));
    final state = surfaceState(tester);
    var previous = state.presentedDanmakuPosition;
    var updates = 0;
    for (var frame = 1; frame <= 120; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
      // Ordinary native notifications and parent rebuilds share the frame cap.
      if (frame % 10 == 0) {
        playback.sample(1 + frame * 8333 / 1e6);
        await tester.pumpWidget(surface(playback, items));
      }
      final current = state.presentedDanmakuPosition;
      if (current != previous) {
        updates++;
        expect(current, greaterThan(previous));
        previous = current;
      }
    }
    expect(updates, inInclusiveRange(55, 60));
    expect(previous, closeTo(2, .025));
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
  });

  testWidgets('dense rolling starts also respect the frame cap', (
    tester,
  ) async {
    final playback = SurfacePlayback(position: 1);
    await tester.pumpWidget(
      surface(
        playback,
        List.generate(300, (index) => comment('${index + 1}', index * .005)),
      ),
    );
    final state = surfaceState(tester);
    var previous = state.presentedDanmakuPosition;
    var updates = 0;
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
      final current = state.presentedDanmakuPosition;
      if (current != previous) {
        updates++;
        previous = current;
      }
    }
    expect(updates, inInclusiveRange(55, 60));
    expect(previous, closeTo(2, .025));
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
  });

  testWidgets('stale pause and final samples freeze until an explicit seek', (
    tester,
  ) async {
    final playback = SurfacePlayback(position: 9.7);
    await tester.pumpWidget(
      surface(playback, [comment('1', 0), comment('2', 9.5)]),
    );
    final state = surfaceState(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.presentedDanmakuPosition, closeTo(10.1, .00001));
    playback.sample(9.7, paused: true);
    expect(state.presentedDanmakuPosition, closeTo(10.1, .00001));
    expect(state.danmakuAnimationActive, isFalse);
    playback.sample(10.12, paused: true);
    await tester.pump(const Duration(minutes: 15));
    expect(state.presentedDanmakuPosition, closeTo(10.1, .00001));
    expect(state.cachedTextPainters, 1);
    playback.sample(10.12);
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.presentedDanmakuPosition, closeTo(10.21, .00001));

    playback.sample(10.05, paused: true, seek: true);
    expect(state.presentedDanmakuPosition, 10.05);
    await tester.pump(const Duration(seconds: 1));
    expect(state.presentedDanmakuPosition, 10.05);
    playback.sample(9.95, paused: true, seek: true);
    await tester.pump();
    expect(state.presentedDanmakuPosition, 9.95);
    expect(state.cachedTextPainters, 2);
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
  });

  testWidgets('changing speed during a gap reschedules the next message', (
    tester,
  ) async {
    final playback = SurfacePlayback(position: 1);
    await tester.pumpWidget(surface(playback, [comment('1', 5)]));
    final state = surfaceState(tester);
    await tester.pump(const Duration(seconds: 1));
    playback.sample(2, rate: 2);
    await tester.pump(const Duration(milliseconds: 1490));
    expect(state.cachedTextPainters, 0);
    await tester.pump(const Duration(milliseconds: 20));
    expect(state.cachedTextPainters, 1);
    expect(state.danmakuAnimationActive, isTrue);
    expect(state.presentedDanmakuPosition, 5);
    await tester.pump(const Duration(microseconds: 16667));
    expect(state.presentedDanmakuPosition, closeTo(5.053334, .000001));
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
  });

  testWidgets('disposing during an empty interval cancels its scheduled wake', (
    tester,
  ) async {
    final playback = SurfacePlayback(position: 1);
    await tester.pumpWidget(surface(playback, [comment('1', 20)]));
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
