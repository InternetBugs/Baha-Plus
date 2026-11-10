import 'dart:async';

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'native_playback_test.dart' show FakeVideo, sourceJson;

PlaybackState _playback({
  double position = 600,
  double duration = 1200,
  bool paused = false,
  PlaybackPhase phase = PlaybackPhase.content,
}) => PlaybackState(
  phase: phase,
  surfaceReady: true,
  buffering: false,
  paused: paused,
  position: position,
  duration: duration,
);

class _SeekPortal extends FakePortal {
  late AppStore store;
  final commands = <(String, double?)>[];
  Completer<void>? pendingSeek;
  Future<bool> Function(String, double?)? commandHandler;
  bool failSeek = false;

  @override
  Future<bool> playerCommand(
    String document,
    String action,
    double? value,
  ) async {
    commands.add((action, value));
    if (commandHandler != null) return commandHandler!(action, value);
    if (action == 'seek') {
      await pendingSeek?.future;
      if (failSeek) throw StateError('Seek failed');
      final state = store.playback.value;
      store.playback.value = _playback(
        position: value!,
        duration: state.duration,
        paused: state.paused,
      );
    }
    return true;
  }
}

void main() {
  final surface = find.byKey(const ValueKey('player-controls-toggle'));
  final slider = find.byKey(const ValueKey('player-progress-slider'));
  final preview = find.byKey(const ValueKey('player-seek-preview'));
  final controls = find.byKey(const ValueKey('video-glass-controls'));
  final portals = <_SeekPortal>[];

  void testSeekWidgets(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        // AppStore owns a playback watchdog independently of PlayerPage.
        // Release the fake portal before Flutter checks pending timers.
        for (final portal in portals) {
          portal.store.detach(portal);
        }
        portals.clear();
        await tester.pumpWidget(const SizedBox.shrink());
        // DoubleTapGestureRecognizer's minimum-tap countdown is not canceled
        // when a competing drag wins or the recognizer is disposed.
        await tester.pump(kDoubleTapTimeout);
      }
    });
  }

  Future<_SeekPortal> launch(
    WidgetTester tester, {
    Size size = const Size(850, 400),
    PlaybackState? state,
    bool fullscreen = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = (await tester.runAsync(
      () =>
          AppStore.create(storage: MemoryStorage(), animeSearch: FakeSearch()),
    ))!;
    addTearDown(store.dispose);
    final portal = _SeekPortal()
      ..store = store
      ..communityResponse = {
        'ok': true,
        'messageId': '123',
        'total': 0,
        'nextPage': 0,
        'comments': <Json>[],
      };
    portals.add(portal);
    await store.attach(portal);
    await store.play(
      const Anime(
        id: '10',
        title: 'Test Anime',
        latestVideoId: '20',
        cover: '',
      ),
    );
    store.playback.value = state ?? _playback();
    store.setPlayerFullscreen(fullscreen);
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MaterialApp(
          home: PlayerPage(
            store: store,
            video: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    await tester.pump();
    return portal;
  }

  double position(WidgetTester tester) =>
      tester.widget<GlassSlider>(slider).value;

  testSeekWidgets(
    'landscape swipes preview precise relative seeks on the player slider',
    (tester) async {
      final portal = await launch(tester);
      final store = portal.store;
      final origin = tester.getCenter(surface);
      final gesture = await tester.startGesture(origin);
      await gesture.moveBy(const Offset(85, 0));
      await tester.pump();
      expect(preview, findsOneWidget);
      expect(position(tester), closeTo(612, .001));
      expect(
        find.text('10:12 / 20:00'),
        findsNWidgets(2),
        reason: 'The center preview and controls share the same target.',
      );
      expect(find.text('+00:12'), findsOneWidget);
      expect(portal.commands, isEmpty);

      // Playback ticks must not move the fixed gesture origin.
      store.playback.value = _playback(position: 603, paused: true);
      await tester.pump(const Duration(seconds: 4));
      expect(controls.hitTestable(), findsOneWidget);
      expect(position(tester), closeTo(612, .001));
      await gesture.moveBy(const Offset(-42.5, 0));
      await tester.pump();
      expect(position(tester), closeTo(606, .001));
      expect(find.text('+00:06'), findsOneWidget);
      await gesture.moveBy(const Offset(-85, 0));
      await tester.pump();
      expect(position(tester), closeTo(594, .001));
      expect(find.text('−00:06'), findsOneWidget);
      expect(portal.commands, isEmpty);

      portal.pendingSeek = Completer<void>();
      await gesture.up();
      await tester.pump();
      expect(portal.commands, [('seek', 594.0)]);
      expect(preview, findsNothing);
      expect(position(tester), 594);
      expect(store.playback.value.position, 603);
      portal.pendingSeek!.complete();
      await tester.pump();
      expect(store.playback.value.position, 594);
      expect(store.playback.value.paused, isTrue);
      expect(position(tester), 594);
      expect(tester.takeException(), isNull);
    },
  );

  testSeekWidgets(
    'hidden controls reveal and stay visible throughout a long swipe',
    (tester) async {
      final portal = await launch(tester);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 150));
      expect(controls.hitTestable(), findsNothing);
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(-85, 0));
      await tester.pump(const Duration(milliseconds: 150));
      expect(controls.hitTestable(), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(controls.hitTestable(), findsOneWidget);
      expect(position(tester), closeTo(588, .001));
      await gesture.up();
      await tester.pump();
      expect(portal.commands, [('seek', 588.0)]);
      expect(portal.store.playback.value.paused, isFalse);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 150));
      expect(controls.hitTestable(), findsNothing);
    },
  );

  for (final duration in [60.0, 1200.0, 7200.0]) {
    testSeekWidgets(
      'swipes clamp and reverse immediately at both ends of a ${duration}s video',
      (tester) async {
        final portal = await launch(
          tester,
          state: _playback(position: 1, duration: duration),
        );
        final secondsPerPixel = duration.clamp(0, 120) / 850;
        final gesture = await tester.startGesture(tester.getCenter(surface));
        await gesture.moveBy(const Offset(-100, 0));
        await tester.pump();
        expect(position(tester), 0);
        await gesture.moveBy(const Offset(5, 0));
        await tester.pump();
        expect(position(tester), closeTo(5 * secondsPerPixel, .001));
        await gesture.up();
        await tester.pump();
        expect(portal.commands.single.$2, closeTo(5 * secondsPerPixel, .001));

        portal.store.playback.value = _playback(
          position: duration - 1,
          duration: duration,
        );
        await tester.pump();
        final next = await tester.startGesture(tester.getCenter(surface));
        await next.moveBy(const Offset(100, 0));
        await tester.pump();
        expect(position(tester), duration);
        await next.moveBy(const Offset(-5, 0));
        await tester.pump();
        expect(position(tester), closeTo(duration - 5 * secondsPerPixel, .001));
        await next.up();
        await tester.pump();
        expect(portal.commands, hasLength(2));
        expect(
          portal.commands.last.$2,
          closeTo(duration - 5 * secondsPerPixel, .001),
        );
      },
    );
  }

  testSeekWidgets('portrait and vertical drags do not seek', (tester) async {
    final portal = await launch(
      tester,
      size: const Size(400, 850),
      fullscreen: false,
    );
    await tester.drag(surface, const Offset(100, 0));
    await tester.pump();
    expect(preview, findsNothing);
    expect(portal.commands, isEmpty);
    expect(position(tester), 600);

    portal.store.setPlayerFullscreen(true);
    tester.view.physicalSize = const Size(850, 400);
    await tester.pump();
    for (final movement in [
      const Offset(0, 100),
      const Offset(5, 100),
      const Offset(-5, -100),
    ]) {
      await tester.drag(surface, movement);
      await tester.pump();
      expect(preview, findsNothing, reason: 'Movement: $movement');
      expect(portal.commands, isEmpty, reason: 'Movement: $movement');
      expect(position(tester), 600);
    }
  });

  testSeekWidgets(
    'locked, advertising and unavailable playback cannot swipe seek',
    (tester) async {
      final portal = await launch(tester);
      portal.store.setPlayerLocked(true);
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('player-locked-surface')),
        const Offset(100, 0),
      );
      await tester.pump();
      expect(preview, findsNothing);
      expect(portal.commands, isEmpty);
      portal.store.setPlayerLocked(false);
      for (final phase in PlaybackPhase.values.where(
        (phase) => phase != PlaybackPhase.content,
      )) {
        portal.store.playback.value = _playback(phase: phase);
        await tester.pump();
        await tester.dragFrom(const Offset(400, 180), const Offset(100, 0));
        await tester.pump();
        expect(preview, findsNothing, reason: phase.name);
        expect(portal.commands, isEmpty, reason: phase.name);
      }
      portal.store.playback.value = _playback(position: 0, duration: 0);
      await tester.pump();
      await tester.dragFrom(const Offset(400, 180), const Offset(100, 0));
      await tester.pump();
      expect(preview, findsNothing);
      expect(portal.commands, isEmpty);
    },
  );

  testSeekWidgets(
    'slider drags and tap controls retain their existing behavior',
    (tester) async {
      final portal = await launch(tester, state: _playback(paused: true));
      final rect = tester.getRect(slider);
      final gesture = await tester.startGesture(rect.center);
      await gesture.moveBy(Offset(rect.width / 4, 0));
      await tester.pump();
      final target = position(tester);
      expect(target, greaterThan(800));
      expect(preview, findsNothing);
      expect(portal.commands, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(portal.commands, [('seek', target)]);
      expect(position(tester), target);

      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 400));
      expect(controls.hitTestable(), findsNothing);
      expect(portal.commands, hasLength(1));
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(surface);
      await tester.pump();
      expect(portal.commands.last.$1, 'play');
      expect(portal.commands, hasLength(2));
    },
  );

  testSeekWidgets(
    'canceled and failed seeks restore the actual playback position',
    (tester) async {
      final portal = await launch(tester);
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(85, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();
      expect(preview, findsNothing);
      expect(position(tester), 600);
      expect(portal.commands, isEmpty);

      final sliderGesture = await tester.startGesture(tester.getCenter(slider));
      await sliderGesture.moveBy(const Offset(85, 0));
      await tester.pump();
      expect(position(tester), isNot(600));
      await sliderGesture.cancel();
      await tester.pump();
      expect(position(tester), 600);
      expect(portal.commands, isEmpty);

      portal.failSeek = true;
      await tester.drag(surface, const Offset(85, 0));
      await tester.pump();
      expect(portal.commands, [('seek', 612.0)]);
      expect(preview, findsNothing);
      expect(position(tester), 600);
      expect(tester.takeException(), isNull);
    },
  );

  for (final interruption in [
    'rotation',
    'exit fullscreen',
    'lock',
    'advertisement',
    'new episode',
  ]) {
    testSeekWidgets('$interruption cancels an active swipe without seeking', (
      tester,
    ) async {
      final portal = await launch(tester);
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(85, 0));
      await tester.pump();
      expect(preview, findsOneWidget);
      switch (interruption) {
        case 'rotation':
          tester.view.physicalSize = const Size(400, 850);
        case 'exit fullscreen':
          portal.store.setPlayerFullscreen(false);
        case 'lock':
          portal.store.setPlayerLocked(true);
        case 'advertisement':
          portal.store.playback.value = _playback(
            phase: PlaybackPhase.advertisement,
          );
        case 'new episode':
          await portal.store.play(
            portal.store.playingAnime!,
            episode: const Episode(id: '21', label: '2'),
          );
          portal.store.playback.value = _playback(position: 10);
      }
      await tester.pump();
      expect(preview, findsNothing);
      await gesture.up();
      await tester.pump();
      expect(portal.commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testSeekWidgets('a finished old command cannot clear a newer swipe preview', (
    tester,
  ) async {
    final portal = await launch(tester);
    portal.pendingSeek = Completer<void>();
    await tester.drag(surface, const Offset(85, 0));
    await tester.pump();
    expect(portal.commands, [('seek', 612.0)]);
    portal.store.setPlayerLocked(true);
    portal.store.setPlayerLocked(false);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await gesture.moveBy(const Offset(-85, 0));
    await tester.pump();
    expect(position(tester), closeTo(588, .001));
    portal.pendingSeek!.complete();
    await tester.pump();
    expect(preview, findsOneWidget);
    expect(position(tester), closeTo(588, .001));
    await gesture.up();
    await tester.pump();
    expect(portal.commands, [('seek', 612.0), ('seek', 588.0)]);
    expect(position(tester), 588);
  });

  testSeekWidgets(
    'a swipe reaches the native video backend with the same target',
    (tester) async {
      final portal = await launch(tester);
      final previousPlatform = VideoPlayerPlatform.instance;
      final platform = FakeVideo();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previousPlatform);
      final native = NativePlayback(
        document: portal.store.operation.id,
        source: NativePlaybackSource.fromJson(sourceJson()),
        userAgent: 'device agent',
        onState: (state) => portal.store.playback.value = state,
      );
      addTearDown(
        () => tester.runAsync(() async {
          native.dispose();
          await native.released;
        }),
      );
      await tester.runAsync(() => native.initialize(0));
      await native.activate(
        applicationActive: true,
        timeline: {'position': 600, 'paused': true, 'rate': 1, 'muted': false},
      );
      portal.commandHandler = native.command;
      await tester.pump();
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(85, 0));
      await tester.pump();
      expect(position(tester), closeTo(612, .001));
      expect(platform.positions.values.single, const Duration(seconds: 600));
      platform.holdSeek = Completer<void>();
      await gesture.up();
      await tester.pump();
      expect(position(tester), 612);
      expect(portal.store.playback.value.position, 612);
      platform.holdSeek!.complete();
      await tester.pump();
      expect(platform.positions.values.single, const Duration(seconds: 612));
      expect(position(tester), 612);
      expect(native.state.paused, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
