import 'fake_playback.dart';
import 'fake_metadata.dart';
import 'dart:async';

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/gestures.dart'
    show kDoubleTapTimeout, kLongPressTimeout;
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
  bool ended = false,
  double rate = 1,
  PlaybackPhase phase = PlaybackPhase.content,
}) => PlaybackState(
  phase: phase,
  surfaceReady: true,
  buffering: false,
  paused: paused,
  ended: ended,
  rate: rate,
  position: position,
  duration: duration,
);

class _SeekPortal extends FakePortal {
  late AppStore store;
  final commands = <(String, double?)>[];
  Completer<void>? pendingSeek;
  Completer<void>? pendingRate;
  Future<bool> Function(String, double?)? commandHandler;
  bool failSeek = false;

  @override
  Future<bool> recordPlayerCommand(
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
        rate: state.rate,
      );
    } else if (action == 'rate') {
      await pendingRate?.future;
      final state = store.playback.value;
      store.playback.value = _playback(
        position: state.position,
        duration: state.duration,
        paused: state.paused,
        rate: value!,
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
  final speedIndicator = find.byKey(
    const ValueKey('player-hold-speed-indicator'),
  );
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
    AnimeDetail? detail,
    bool fullscreen = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = (await tester.runAsync(
      () => AppStore.create(
        nativeHttpApiFactory: PendingNativeHttpApi.new,
        metadataApi: FakeMetadata(),
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
      ),
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
    await playFixture(
      store,
      const Anime(
        id: '10',
        title: 'Test Anime',
        latestVideoId: '20',
        cover: '',
      ),

      onCommand: (action, value) =>
          portal.recordPlayerCommand(store.operation.id, action, value),
    );
    store.playback.value = state ?? _playback();
    if (detail != null) store.playerDetail = detail;
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

  Offset gestureOrigin(WidgetTester tester) {
    final rect = tester.getRect(surface);
    return Offset(rect.left + rect.width * .22, rect.center.dy);
  }

  for (final fullscreen in [false, true]) {
    for (final rate in [1.0, 1.5, 2.0]) {
      testSeekWidgets(
        '${fullscreen ? 'fullscreen' : 'portrait'} holds use 2x and restore $rate',
        (tester) async {
          final portal = await launch(
            tester,
            size: fullscreen ? const Size(850, 400) : const Size(400, 850),
            fullscreen: fullscreen,
            state: _playback(rate: rate),
          );
          final gesture = await tester.startGesture(gestureOrigin(tester));
          await tester.pump(
            kLongPressTimeout - const Duration(milliseconds: 1),
          );
          expect(portal.commands, isEmpty);
          // Small hand movements should not prevent a stationary hold.
          await gesture.moveBy(const Offset(3, 2));
          await tester.pump(const Duration(milliseconds: 2));
          expect(portal.commands, [('rate', 2.0)]);
          expect(speedIndicator, findsOneWidget);
          expect(portal.store.playback.value.rate, 2);
          expect(portal.store.playback.value.position, 600);
          expect(portal.store.playback.value.paused, isFalse);
          await tester.pump(const Duration(seconds: 1));
          expect(portal.commands, hasLength(1));
          await gesture.up();
          await tester.pump();
          expect(portal.commands, [('rate', 2.0), ('rate', rate)]);
          expect(portal.store.playback.value.rate, rate);
          expect(speedIndicator, findsNothing);
          expect(preview, findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final movement in [
    const Offset(85, 0),
    const Offset(-85, 0),
    const Offset(0, 85),
    const Offset(0, -85),
  ]) {
    testSeekWidgets('movement $movement before a hold never speeds up', (
      tester,
    ) async {
      final portal = await launch(tester);
      final gesture = await tester.startGesture(gestureOrigin(tester));
      await gesture.moveBy(movement);
      await tester.pump(kLongPressTimeout);
      expect(speedIndicator, findsNothing);
      expect(portal.commands, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(portal.commands.where((command) => command.$1 == 'rate'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testSeekWidgets('movement $movement after a hold restores speed', (
      tester,
    ) async {
      final portal = await launch(tester, state: _playback(rate: 1.25));
      final gesture = await tester.startGesture(gestureOrigin(tester));
      await tester.pump(kLongPressTimeout);
      expect(speedIndicator, findsOneWidget);
      await gesture.moveBy(movement);
      await tester.pump();
      expect(speedIndicator, findsNothing);
      expect(preview, findsNothing);
      expect(portal.commands, [('rate', 2.0), ('rate', 1.25)]);
      await gesture.moveBy(-movement);
      await tester.pump(kLongPressTimeout);
      await gesture.up();
      await tester.pump();
      expect(portal.commands, hasLength(2));
      expect(tester.takeException(), isNull);
    });
  }

  testSeekWidgets('canceling an accepted hold restores speed', (tester) async {
    final portal = await launch(tester, state: _playback(rate: .75));
    final gesture = await tester.startGesture(gestureOrigin(tester));
    await tester.pump(kLongPressTimeout);
    expect(speedIndicator, findsOneWidget);
    await gesture.cancel();
    await tester.pump();
    expect(speedIndicator, findsNothing);
    expect(portal.commands, [('rate', 2.0), ('rate', .75)]);
    expect(tester.takeException(), isNull);
  });

  testSeekWidgets(
    'releasing before a rate command finishes restores in order',
    (tester) async {
      final portal = await launch(tester, state: _playback(rate: 1.75));
      portal.pendingRate = Completer<void>();
      final gesture = await tester.startGesture(gestureOrigin(tester));
      await tester.pump(kLongPressTimeout);
      expect(portal.commands, [('rate', 2.0)]);
      await gesture.up();
      await tester.pump();
      expect(speedIndicator, findsNothing);
      expect(portal.commands, hasLength(1));
      portal.pendingRate!.complete();
      await tester.pump();
      expect(portal.commands, [('rate', 2.0), ('rate', 1.75)]);
      expect(portal.store.playback.value.rate, 1.75);
      expect(tester.takeException(), isNull);
    },
  );

  testSeekWidgets(
    'paused, ended, locked and unavailable playback cannot hold',
    (tester) async {
      final portal = await launch(tester);
      final origin = gestureOrigin(tester);
      for (final state in [
        _playback(paused: true),
        _playback(ended: true),
        _playback(duration: 0, position: 0),
        for (final phase in PlaybackPhase.values.where(
          (phase) => phase != PlaybackPhase.content,
        ))
          _playback(phase: phase),
      ]) {
        portal.store.playback.value = state;
        await tester.pump();
        final gesture = await tester.startGesture(origin);
        await tester.pump(kLongPressTimeout);
        await gesture.up();
        await tester.pump(kDoubleTapTimeout);
        expect(speedIndicator, findsNothing);
        expect(portal.commands, isEmpty);
      }
      portal.store.playback.value = _playback();
      portal.store.setPlayerLocked(true);
      await tester.pump();
      final gesture = await tester.startGesture(origin);
      await tester.pump(kLongPressTimeout);
      await gesture.up();
      await tester.pump();
      expect(speedIndicator, findsNothing);
      expect(portal.commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final interruption in [
    'rotation',
    'exit fullscreen',
    'lock',
    'pause',
    'advertisement',
    'background',
    'new episode',
    'dispose',
  ]) {
    testSeekWidgets(
      '$interruption ends a hold and preserves the original rate',
      (tester) async {
        final portal = await launch(tester, state: _playback(rate: 1.5));
        final store = portal.store;
        final gesture = await tester.startGesture(gestureOrigin(tester));
        await tester.pump(kLongPressTimeout);
        expect(portal.commands, [('rate', 2.0)]);
        expect(speedIndicator, findsOneWidget);
        switch (interruption) {
          case 'rotation':
            tester.view.physicalSize = const Size(400, 850);
          case 'exit fullscreen':
            store.setPlayerFullscreen(false);
          case 'lock':
            store.setPlayerLocked(true);
          case 'pause':
            store.playback.value = _playback(paused: true, rate: 2);
          case 'advertisement':
            store.playback.value = _playback(
              phase: PlaybackPhase.advertisement,
            );
          case 'background':
            await store.setApplicationActive(false);
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
          case 'new episode':
            await playFixture(
              store,
              store.playingAnime!,
              episode: const Episode(id: '21', label: '2'),

              onCommand: (action, value) =>
                  portal.recordPlayerCommand(store.operation.id, action, value),
            );
            store.playback.value = _playback(position: 10);
          case 'dispose':
            await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.pump();
        // Flutter suppresses frames while hidden; the rendered tree catches up
        // when the application resumes.
        if (interruption != 'background') {
          expect(speedIndicator, findsNothing);
        }
        await gesture.up();
        await tester.pump();
        if (interruption == 'advertisement' || interruption == 'background') {
          expect(portal.commands, [
            ('rate', 2.0),
            if (interruption == 'background') ('pause', null),
          ]);
          if (interruption == 'background') {
            await store.setApplicationActive(true);
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          } else {
            store.playback.value = _playback(rate: 2);
          }
          await tester.pump();
        }
        expect(speedIndicator, findsNothing);
        expect(
          portal.commands,
          interruption == 'new episode'
              ? [('rate', 2.0)]
              : [
                  ('rate', 2.0),
                  if (interruption == 'background') ('pause', null),
                  ('rate', 1.5),
                ],
        );
        if (interruption == 'background') {
          expect(store.playback.value.paused, isTrue);
        }
        expect(
          store.playback.value.rate,
          interruption == 'new episode' ? 1 : 1.5,
        );
        expect(preview, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testSeekWidgets(
    'landscape swipes preview precise relative seeks on the player slider',
    (tester) async {
      final portal = await launch(tester);
      final store = portal.store;
      final origin = gestureOrigin(tester);
      final gesture = await tester.startGesture(origin);
      await gesture.moveBy(const Offset(85, 0));
      await tester.pump();
      expect(preview, findsOneWidget);
      expect(find.byKey(const ValueKey('player-center-controls')), findsNothing);
      expect(position(tester), closeTo(612, .001));
      expect(
        find.descendant(of: preview, matching: find.text('10:12 / 20:00')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: controls, matching: find.text('10:12')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: controls, matching: find.text('20:00')),
        findsOneWidget,
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
        final gesture = await tester.startGesture(gestureOrigin(tester));
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
        final next = await tester.startGesture(gestureOrigin(tester));
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

  testSeekWidgets('portrait video pins while controls and details scroll', (
    tester,
  ) async {
    final portal = await launch(
      tester,
      size: const Size(400, 640),
      fullscreen: false,
      detail: AnimeDetail.fromJson({
        'title': 'Test Anime',
        'description': 'Synopsis',
        'episodes': [],
        'metadata': [
          for (var index = 1; index <= 10; index++)
            {'label': 'Credit $index', 'value': 'Name $index'},
        ],
      }),
    );
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final title = find.text('Test Anime');
    final controlsTop = tester.getTopLeft(controls).dy;
    final videoTop = tester.getTopLeft(surface).dy;
    final titleTop = tester.getTopLeft(title).dy;
    final video = tester.element(surface);

    Future<void> doubleTapVideo() async {
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(surface);
      await tester.pump();
    }

    await tester.drag(surface, const Offset(0, -140));
    await tester.pump();

    final offset = scroll.pixels;
    expect(offset, greaterThan(0));
    expect(tester.getTopLeft(controls).dy, closeTo(controlsTop - offset, .01));
    expect(tester.getTopLeft(title).dy, closeTo(titleTop - offset, .01));
    expect(tester.getTopLeft(surface).dy, videoTop);
    expect(find.byIcon(CupertinoIcons.pause_fill).hitTestable(), findsNothing);
    expect(portal.commands, isEmpty);

    final hold = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(kLongPressTimeout);
    expect(speedIndicator, findsOneWidget);
    expect(portal.commands, [('rate', 2.0)]);
    await hold.up();
    await tester.pump();
    expect(speedIndicator, findsNothing);
    expect(portal.commands, [('rate', 2.0), ('rate', 1.0)]);

    await doubleTapVideo();
    expect(portal.commands.last, ('pause', null));

    portal.store.playback.value = _playback(paused: true);
    await tester.pump();
    expect(scroll.pixels, offset);
    expect(tester.getTopLeft(surface).dy, closeTo(videoTop - offset, .01));
    expect(tester.element(surface), same(video));

    scroll.jumpTo(0);
    await tester.pump();
    await doubleTapVideo();
    expect(portal.commands.last, ('play', null));

    scroll.jumpTo(offset);
    portal.store.playback.value = _playback();
    await tester.pump();
    expect(scroll.pixels, offset);
    expect(tester.getTopLeft(surface).dy, videoTop);
    expect(tester.element(surface), same(video));

    portal.store.playback.value = _playback(ended: true);
    await tester.pump();
    expect(tester.getTopLeft(surface).dy, closeTo(videoTop - offset, .01));

    tester.view.physicalSize = const Size(800, 460);
    portal.store.playback.value = _playback();
    scroll.jumpTo(0);
    await tester.pump();
    final landscapeVideoTop = tester.getTopLeft(surface).dy;
    scroll.jumpTo(offset);
    await tester.pump();
    expect(
      tester.getTopLeft(surface).dy,
      closeTo(landscapeVideoTop - offset, .01),
    );
  });

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
      await tester.dragFrom(gestureOrigin(tester), movement);
      await tester.pump();
      expect(preview, findsNothing, reason: 'Movement: $movement');
      expect(portal.commands, isEmpty, reason: 'Movement: $movement');
      expect(position(tester), 600);
    }
  });

  testSeekWidgets(
    'a pull starting in the top exempt strip never seeks',
    (tester) async {
      final portal = await launch(tester);
      final rect = tester.getRect(surface);
      expect(rect.top, 0);
      // System pull-down territory: straight down, slightly slanted and
      // clearly diagonal pulls must all stay out of the seek gesture.
      for (final movement in [
        const Offset(0, 120),
        const Offset(20, 120),
        const Offset(120, 160),
        const Offset(-120, 160),
      ]) {
        final gesture = await tester.startGesture(rect.topCenter);
        await gesture.moveBy(movement);
        await tester.pump();
        expect(preview, findsNothing, reason: 'Movement: $movement');
        await gesture.up();
        await tester.pump();
        expect(preview, findsNothing, reason: 'Movement: $movement');
        expect(portal.commands, isEmpty, reason: 'Movement: $movement');
        expect(position(tester), 600, reason: 'Movement: $movement');
      }
      // The strip is only the top edge; a drag below it still seeks.
      await tester.dragFrom(
        rect.topCenter + const Offset(0, 60),
        const Offset(85, 0),
      );
      await tester.pump();
      expect(portal.commands, [('seek', 612.0)]);
      expect(position(tester), 612);
    },
  );

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
        await tester.dragFrom(const Offset(180, 180), const Offset(100, 0));
        await tester.pump();
        expect(preview, findsNothing, reason: phase.name);
        expect(portal.commands, isEmpty, reason: phase.name);
      }
      portal.store.playback.value = _playback(position: 0, duration: 0);
      await tester.pump();
      await tester.dragFrom(const Offset(180, 180), const Offset(100, 0));
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

      await tester.tapAt(gestureOrigin(tester));
      await tester.pump(const Duration(milliseconds: 400));
      expect(controls.hitTestable(), findsNothing);
      expect(
        find.byKey(const ValueKey('player-center-controls')).hitTestable(),
        findsNothing,
      );
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
      final gesture = await tester.startGesture(gestureOrigin(tester));
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
      await tester.dragFrom(gestureOrigin(tester), const Offset(85, 0));
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
      final gesture = await tester.startGesture(gestureOrigin(tester));
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
    await tester.dragFrom(gestureOrigin(tester), const Offset(85, 0));
    await tester.pump();
    expect(portal.commands, [('seek', 612.0)]);
    portal.store.setPlayerLocked(true);
    portal.store.setPlayerLocked(false);
    await tester.pump();
    final gesture = await tester.startGesture(gestureOrigin(tester));
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
    'a stationary hold changes and restores the native video playback rate',
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
      try {
        await tester.runAsync(() => native.initialize(0));
        await native.activate(
          applicationActive: true,
          timeline: {
            'position': 600,
            'paused': false,
            'rate': 1.5,
            'muted': false,
          },
        );
        portal.commandHandler = native.command;
        await tester.pump();
        final playCalls = platform.playCalls.length;
        final gesture = await tester.startGesture(gestureOrigin(tester));
        await tester.pump(kLongPressTimeout);
        expect(speedIndicator, findsOneWidget);
        expect(native.state.rate, 2);
        expect(native.state.paused, isFalse);
        expect(platform.positions.values.single, const Duration(seconds: 600));
        await gesture.up();
        await tester.pump();
        expect(speedIndicator, findsNothing);
        expect(native.state.rate, 1.5);
        expect(native.state.paused, isFalse);
        expect(platform.playCalls, hasLength(playCalls));
        expect(portal.commands, [('rate', 2.0), ('rate', 1.5)]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() async {
          native.dispose();
          await native.released;
        });
      }
    },
  );

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
      final gesture = await tester.startGesture(gestureOrigin(tester));
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

  testSeekWidgets(
    'long-pressing forward skips 85 seconds inside the OP window',
    (tester) async {
      final portal = await launch(tester, state: _playback(position: 30));
      final forward = find.byIcon(CupertinoIcons.goforward_10);
      expect(forward, findsOneWidget);
      await tester.longPress(forward);
      await tester.pump();
      expect(portal.commands, [('seek', 115.0)]);
      expect(portal.store.playback.value.position, 115);
      expect(tester.takeException(), isNull);
    },
  );

  testSeekWidgets(
    'long-pressing forward stays a ten-second tap outside the OP window',
    (tester) async {
      final portal = await launch(tester, state: _playback(position: 300));
      await tester.longPress(find.byIcon(CupertinoIcons.goforward_10));
      await tester.pump();
      expect(portal.commands, [('seek', 310.0)]);
      expect(tester.takeException(), isNull);
    },
  );

  testSeekWidgets(
    'long-pressing forward stays a ten-second tap when disabled',
    (tester) async {
      final portal = await launch(tester, state: _playback(position: 30));
      await portal.store.setSkipOpLongPress(false);
      await tester.pump();
      await tester.longPress(find.byIcon(CupertinoIcons.goforward_10));
      await tester.pump();
      expect(portal.commands, [('seek', 40.0)]);
      expect(tester.takeException(), isNull);
    },
  );

  testSeekWidgets(
    'long-pressing forward skips only once per episode',
    (tester) async {
      final portal = await launch(tester, state: _playback(position: 30));
      final forward = find.byIcon(CupertinoIcons.goforward_10);
      await tester.longPress(forward);
      await tester.pump();
      await tester.longPress(forward);
      await tester.pump();
      expect(portal.commands, [('seek', 115.0), ('seek', 125.0)]);
      expect(tester.takeException(), isNull);
    },
  );

  testSeekWidgets(
    'fullscreen separates center transport controls from the slim bottom scrubber and adapts phone vs tablet sizing',
    (tester) async {
      final portal = await launch(
        tester,
        size: const Size(844, 390),
        state: _playback(position: 125, duration: 1440),
      );
      final centerControls = find.byKey(
        const ValueKey('player-center-controls'),
      );
      final topCapsule = find.byKey(
        const ValueKey('player-top-actions-capsule'),
      );
      final closeBtn = find.byKey(const ValueKey('player-fullscreen-close'));
      final lockBtn = find.byKey(const ValueKey('player-lock'));

      // Phone landscape: slim single-row bottom bar + unified 36pt top/lock controls.
      final phoneBar = tester.getRect(controls);
      final phoneCenter = tester.getRect(centerControls);
      final phoneTopCapsule = tester.getRect(topCapsule);
      expect(phoneBar.height, closeTo(44, 1));
      expect(phoneCenter.bottom, lessThan(phoneBar.top));
      expect(tester.getSize(closeBtn), const Size(36, 36));
      expect(tester.getSize(lockBtn), const Size(36, 36));
      expect(phoneTopCapsule.height, closeTo(36, 1));
      expect(
        find.descendant(of: controls, matching: find.text('02:05')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: controls, matching: find.text('24:00')),
        findsOneWidget,
      );

      // Center transport actions trigger play/pause and relative seeks.
      await tester.tap(find.byIcon(CupertinoIcons.gobackward_10));
      await tester.pump();
      await tester.tap(find.byIcon(CupertinoIcons.pause_fill));
      await tester.pump();
      expect(portal.commands, [('seek', 115.0), ('pause', null)]);

      // Buffering hides the center transport buttons to avoid overlapping the spinner.
      portal.store.playback.value = const PlaybackState(
        phase: PlaybackPhase.content,
        surfaceReady: true,
        paused: false,
        buffering: true,
        duration: 1440,
        position: 115,
      );
      await tester.pump();
      expect(centerControls, findsNothing);
      expect(
        find.byKey(const ValueKey('player-loading-indicator')),
        findsOneWidget,
      );
      portal.store.playback.value = _playback(position: 115, duration: 1440);
      await tester.pump();
      expect(centerControls, findsOneWidget);

      // Tablet fullscreen scales up to 40pt top/lock controls and 48pt bottom pill.
      tester.view.physicalSize = const Size(1180, 820);
      await tester.pump();
      expect(tester.getRect(controls).height, closeTo(48, 1));
      expect(tester.getSize(closeBtn), const Size(40, 40));
      expect(tester.getSize(lockBtn), const Size(40, 40));
      expect(tester.getRect(topCapsule).height, closeTo(40, 1));

      // Narrow Split View fullscreen stays overflow-free.
      tester.view.physicalSize = const Size(320, 640);
      await tester.pump();
      expect(tester.getRect(controls).width, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    },
  );
}
