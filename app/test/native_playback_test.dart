import 'dart:async';
import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/ui/native_video_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

Map<String, dynamic> sourceJson() => {
  'master': 'https://bahamut.akamaized.net/master.m3u8',
  'variants': [
    {'height': 360, 'url': 'https://bahamut.akamaized.net/360.m3u8'},
    {'height': 1080, 'url': 'https://bahamut.akamaized.net/1080.m3u8'},
  ],
  'position': 10,
  'duration': 1200,
  'rate': 1,
  'paused': false,
  'muted': false,
};

class FakeVideo extends VideoPlayerPlatform {
  Completer<void>? holdCreation;
  Completer<void>? holdSeek;
  Completer<Duration>? nextPositionResult;
  int positionQueries = 0;
  final sources = <DataSource>[];
  final options = <VideoCreationOptions>[];
  final streams = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final released = <int>[];
  final playing = <int>{};
  final playCalls = <int>[];

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    await holdCreation?.future;
    final id = sources.length;
    this.options.add(options);
    sources.add(options.dataSource);
    positions[id] = Duration.zero;
    streams[id] = StreamController<VideoEvent>(onCancel: () async {})
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 1200),
          size: const Size(1920, 1080),
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    released.add(playerId);
  }

  @override
  Future<void> play(int playerId) async {
    playCalls.add(playerId);
    playing.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    playing.remove(playerId);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    await holdSeek?.future;
    positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    positionQueries++;
    final pending = nextPositionResult;
    nextPositionResult = null;
    if (pending != null) return pending.future;
    return positions[playerId]!;
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeVideo platform;
  setUp(() {
    platform = FakeVideo();
    VideoPlayerPlatform.instance = platform;
  });
  NativePlayback create() => NativePlayback(
    document: 'current',
    source: NativePlaybackSource.fromJson(sourceJson()),
    userAgent: 'device agent',
    onState: (_) {},
  );

  Future<void> withPlayingPluginTimer(
    WidgetTester tester,
    Future<void> Function(NativePlayback) body,
  ) async {
    final native = create();
    try {
      await tester.runAsync(() => native.initialize(0));
      // Start playback in fake time so pump(100ms) runs the real video_player
      // timer, rather than a test replacing controller.value by hand.
      await native.activate(
        applicationActive: true,
        timeline: {'position': 42, 'paused': false, 'rate': 1, 'muted': false},
      );
      await body(native);
    } finally {
      // Initialization creates plugin futures in runAsync's real async zone.
      // Finish their disposal there before Flutter checks for pending timers.
      await tester.runAsync(() async {
        native.dispose();
        await native.released;
      });
    }
  }

  test(
    'native sources reject foreign media, duplicate variants and invalid timelines',
    () {
      for (final raw in [
        {...sourceJson(), 'master': 'https://evil.example/video.m3u8'},
        {...sourceJson(), 'position': -1},
        {
          ...sourceJson(),
          'variants': [
            {'height': 360, 'url': 'https://bahamut.akamaized.net/a.m3u8'},
            {'height': 360, 'url': 'https://bahamut.akamaized.net/b.m3u8'},
          ],
        },
      ]) {
        expect(() => NativePlaybackSource.fromJson(raw), throwsFormatException);
      }
    },
  );

  test(
    'the host owns lifecycle and screen wake instead of plugin foreground auto-resume',
    () async {
      final native = create();
      await native.initialize(0);
      final options = platform.options.single.videoPlayerOptions!;
      expect(options.allowBackgroundPlayback, isTrue);
      expect(options.preventsDisplaySleepDuringVideoPlayback, isFalse);
      expect(options.mixWithOthers, isFalse);
      native.dispose();
    },
  );

  test(
    'a background round trip while handoff seeks cannot resume playback',
    () async {
      final native = create();
      await native.initialize(0);
      final held = platform.holdSeek = Completer<void>();
      final activation = native.activate(
        applicationActive: true,
        timeline: {'position': 42, 'paused': false, 'rate': 1, 'muted': false},
      );
      await Future<void>.delayed(Duration.zero);
      await native.setApplicationActive(false);
      await native.setApplicationActive(true);
      held.complete();
      await activation;
      expect(native.active, isTrue);
      expect(native.state.paused, isTrue);
      expect(platform.playCalls, isEmpty);
      native.dispose();
    },
  );

  test(
    'pause received during a quality change prevents the replacement from playing',
    () async {
      final native = create();
      await native.initialize(0);
      await native.activate(
        applicationActive: true,
        timeline: {'position': 42, 'paused': false, 'rate': 1, 'muted': false},
      );
      final held = platform.holdCreation = Completer<void>();
      final changing = native.command('quality', 360);
      await Future<void>.delayed(Duration.zero);
      final pause = native.command('pause', null);
      held.complete();
      expect(await changing, isTrue);
      expect(await pause, isTrue);
      expect(platform.playCalls, [0]);
      expect(native.state.paused, isTrue);
      native.dispose();
    },
  );

  test(
    'exiting during a quality load releases both old and pending players',
    () async {
      final native = create();
      await native.initialize(0);
      await native.activate(
        applicationActive: true,
        timeline: {'position': 42, 'paused': false, 'rate': 1, 'muted': false},
      );
      final held = platform.holdCreation = Completer<void>();
      final changing = native.command('quality', 360);
      await Future<void>.delayed(Duration.zero);
      native.dispose();
      held.complete();
      expect(await changing, isFalse);
      expect(native.video, isNull);
      expect(platform.released.toSet(), {0, 1});
      expect(platform.playCalls, [0]);
    },
  );

  test(
    'native initial quality, handoff clock and later quality switches preserve user state',
    () async {
      final native = create();
      await native.initialize(1080);
      expect(platform.sources.single.uri, contains('/1080.m3u8'));
      expect(
        platform.sources.single.httpHeaders['Origin'],
        'https://ani.gamer.com.tw',
      );
      expect(platform.playing, isEmpty);
      await native.activate(
        applicationActive: true,
        timeline: {'position': 42, 'paused': false, 'rate': 1.5, 'muted': true},
      );
      expect(native.state.position, 42);
      expect(native.state.rate, 1.5);
      expect(native.state.muted, isTrue);
      await native.command('pause', null);
      await native.command('quality', 360);
      expect(native.state.quality, 360);
      expect(native.state.paused, isTrue);
      expect(native.state.position, 42);
      expect(native.state.rate, 1.5);
      expect(native.state.muted, isTrue);
      await native.command('quality', 0);
      expect(platform.sources.last.uri, contains('/master.m3u8'));
      expect(native.state.quality, 0);
      expect(await native.command('quality', 720), isFalse);
      native.dispose();
      await native.released;
      expect(platform.released.length, platform.sources.length);
    },
  );

  test(
    'background activation stays paused and rejects play commands',
    () async {
      final native = create();
      await native.initialize(0);
      await native.activate(
        applicationActive: false,
        timeline: {'position': 30, 'paused': false, 'rate': 1, 'muted': false},
      );
      expect(native.state.paused, isTrue);
      expect(await native.command('play', null), isFalse);
      expect(native.state.paused, isTrue);
      await native.setApplicationActive(true);
      expect(native.state.paused, isTrue);
      native.dispose();
    },
  );

  test(
    'a quality load finishing after a background round trip remains paused',
    () async {
      final native = create();
      await native.initialize(1080);
      await native.activate(
        applicationActive: true,
        timeline: {'position': 42, 'paused': false, 'rate': 1, 'muted': false},
      );
      final held = platform.holdCreation = Completer<void>();
      final changing = native.command('quality', 360);
      await Future<void>.delayed(Duration.zero);
      await native.setApplicationActive(false);
      await native.setApplicationActive(true);
      held.complete();
      expect(await changing, isTrue);
      expect(native.state.paused, isTrue);
      expect(native.state.position, 42);
      native.dispose();
    },
  );

  test(
    'native buffer events publish separate cached ranges and clear on source replacement',
    () async {
      final states = <PlaybackState>[];
      final native = NativePlayback(
        document: 'current',
        source: NativePlaybackSource.fromJson(sourceJson()),
        userAgent: 'device agent',
        onState: states.add,
      );
      addTearDown(native.dispose);
      await native.initialize(0);
      await native.activate(
        applicationActive: true,
        timeline: {'position': 620, 'paused': true, 'rate': 1, 'muted': false},
      );
      platform.streams[0]!.add(
        VideoEvent(
          eventType: VideoEventType.bufferingUpdate,
          buffered: [
            DurationRange(
              const Duration(seconds: 30),
              const Duration(seconds: 90),
            ),
            DurationRange(
              const Duration(seconds: 600),
              const Duration(seconds: 750),
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(states.last.buffered, 750);
      expect(states.last.bufferRanges, [
        (start: 30.0, end: 90.0),
        (start: 600.0, end: 750.0),
      ]);
      expect(await native.command('quality', 1080), isTrue);
      expect(native.state.buffered, 0);
      expect(native.state.bufferRanges, isEmpty);
    },
  );

  test(
    'native controller position notifications update the clock and only explicit seeks change its revision',
    () async {
      final native = create();
      await native.initialize(0);
      await native.activate(
        applicationActive: true,
        timeline: {'position': 42, 'paused': true, 'rate': 1, 'muted': false},
      );
      final revision = native.seekRevision;
      native.video!.value = native.video!.value.copyWith(
        position: const Duration(milliseconds: 42500),
      );
      expect(native.state.position, 42.5);
      expect(native.seekRevision, revision);
      await native.command('pause', null);
      expect(native.seekRevision, revision);
      await native.command('seek', 42.6);
      expect(native.seekRevision, revision + 1);
      expect(native.state.position, 42.6);
      expect(await native.command('seek', double.nan), isFalse);
      expect(native.seekRevision, revision + 1);
      native.dispose();
    },
  );

  test(
    'a pending paused seek publishes its revision with the target before old buffering events',
    () async {
      final native = create();
      await native.initialize(0);
      await native.activate(
        applicationActive: true,
        timeline: {'position': 42, 'paused': true, 'rate': 1, 'muted': false},
      );
      final revision = native.seekRevision;
      final samples = <(int, double)>[];
      native.addListener(
        () => samples.add((native.seekRevision, native.state.position)),
      );
      final held = platform.holdSeek = Completer<void>();
      final seeking = native.command('seek', 42.1);
      await Future<void>.delayed(Duration.zero);
      native.video!.value = native.video!.value.copyWith(isBuffering: true);
      expect(samples, isNotEmpty);
      expect(samples, everyElement((revision + 1, 42.1)));
      held.complete();
      expect(await seeking, isTrue);
      expect(native.state.position, 42.1);
      expect(native.seekRevision, revision + 1);
      native.dispose();
    },
  );

  for (final paused in [true, false]) {
    for (final (direction, target) in [
      ('forward', 100.0),
      ('backward', 10.0),
      ('small forward', 42.1),
      ('small backward', 41.9),
    ]) {
      testWidgets(
        'plugin timer rejects late position after ${paused ? 'paused' : 'playing'} $direction seek',
        (tester) => withPlayingPluginTimer(tester, (native) async {
          final oldPosition = platform.nextPositionResult =
              Completer<Duration>();
          final queries = platform.positionQueries;
          await tester.pump(const Duration(milliseconds: 100));
          expect(platform.positionQueries, queries + 1);
          expect(oldPosition.isCompleted, isFalse);
          if (paused) expect(await native.command('pause', null), isTrue);

          final revision = native.seekRevision;
          expect(await native.command('seek', target), isTrue);
          final targetTime = Duration(milliseconds: (target * 1000).round());
          expect(native.video!.value.position, targetTime);
          expect(native.state.position, target);
          expect(native.state.paused, paused);

          final lateNotifications = <double>[];
          void record() => lateNotifications.add(native.state.position);
          native.addListener(record);
          oldPosition.complete(const Duration(seconds: 42));
          await tester.pump();
          native.removeListener(record);

          // Both the plugin's cached value and the host clock must retain the
          // target. Guarding only NativePlayback._samplePosition is insufficient.
          expect(native.video!.value.position, targetTime);
          expect(native.state.position, target);
          expect(native.seekRevision, revision + 1);
          expect(native.state.paused, paused);
          expect(lateNotifications, isEmpty);

          // A later poll from the new epoch must still update normally.
          final freshPosition = targetTime + const Duration(milliseconds: 125);
          platform.positions[0] = freshPosition;
          if (paused) expect(await native.command('play', null), isTrue);
          final freshQueries = platform.positionQueries;
          await tester.pump(const Duration(milliseconds: 100));
          expect(platform.positionQueries, freshQueries + 1);
          expect(native.video!.value.position, freshPosition);
          expect(native.state.position, closeTo(target + .125, .000001));
          expect(native.seekRevision, revision + 1);
        }),
      );
    }
  }

  testWidgets(
    'plugin timer skips platform queries while a seek is pending',
    (tester) => withPlayingPluginTimer(tester, (native) async {
      await tester.pump(const Duration(milliseconds: 100));
      final held = platform.holdSeek = Completer<void>();
      final seeking = native.command('seek', 100);
      await tester.pump();
      final queries = platform.positionQueries;
      expect(native.state.position, 100);
      await tester.pump(const Duration(milliseconds: 400));
      expect(platform.positionQueries, queries);
      expect(await native.video!.position, isNull);
      expect(platform.positionQueries, queries);
      held.complete();
      expect(await seeking, isTrue);
      expect(native.video!.value.position, const Duration(seconds: 100));
      expect(await native.video!.position, const Duration(seconds: 100));
    }),
  );

  testWidgets(
    'position queries wait for all overlapping controller seeks',
    (tester) => withPlayingPluginTimer(tester, (native) async {
      final controller = native.video!;
      final firstHold = platform.holdSeek = Completer<void>();
      final firstSeek = controller.seekTo(const Duration(seconds: 100));
      await tester.pump();
      final secondHold = platform.holdSeek = Completer<void>();
      final secondSeek = controller.seekTo(const Duration(seconds: 200));
      await tester.pump();
      final queries = platform.positionQueries;

      secondHold.complete();
      await secondSeek;
      expect(await controller.position, isNull);
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.positionQueries, queries);

      firstHold.complete();
      await firstSeek;
      expect(await controller.position, const Duration(seconds: 100));
    }),
  );

  testWidgets(
    'a failed seek releases the position query guard',
    (tester) => withPlayingPluginTimer(tester, (native) async {
      final revision = native.seekRevision;
      final held = platform.holdSeek = Completer<void>();
      final seeking = native.command('seek', 100);
      final rejected = expectLater(seeking, throwsStateError);
      await tester.pump();
      held.completeError(StateError('Platform seek failed'));
      await rejected;
      platform.holdSeek = null;
      expect(native.state.position, 42);
      expect(native.seekRevision, revision + 2);
      expect(await native.video!.position, const Duration(seconds: 42));
      expect(await native.command('seek', 42.1), isTrue);
      expect(await native.video!.position, const Duration(milliseconds: 42100));
    }),
  );

  testWidgets(
    'native danmaku keeps only bounded live text painters and releases them when disabled',
    (tester) async {
      final native = create();
      await tester.runAsync(() async {
        await native.initialize(0);
        await native.activate(
          applicationActive: false,
          timeline: {'position': 5, 'paused': true, 'rate': 1, 'muted': false},
        );
      });
      final items = List.generate(
        2000,
        (index) => NativeDanmaku.fromJson({
          'id': '${index + 1}',
          'text': '弹幕 $index',
          'time': 1,
          'size': 18,
          'mode': 'rolling',
          'color': '#FFFFFF',
        }),
      );
      Widget surface(DanmakuSettings settings) => MaterialApp(
        home: SizedBox(
          width: 800,
          height: 450,
          child: NativeVideoSurface(
            playback: native,
            danmaku: items,
            settings: settings,
            errorLabel: 'error',
            retryLabel: 'retry',
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpWidget(surface(const DanmakuSettings()));
      await tester.pump();
      final state = tester.state<NativeVideoSurfaceState>(
        find.byType(NativeVideoSurface),
      );
      expect(state.cachedTextPainters, greaterThan(0));
      expect(state.cachedTextPainters, lessThanOrEqualTo(64));
      expect(state.cachedRasterImages, greaterThan(0));
      expect(state.cachedRasterBytes, lessThanOrEqualTo(16 * 1024 * 1024));
      await tester.pumpWidget(surface(const DanmakuSettings(enabled: false)));
      await tester.pump();
      expect(state.cachedTextPainters, 0);
      expect(state.cachedRasterImages, 0);
      expect(state.cachedRasterBytes, 0);
      await tester.pumpWidget(const SizedBox());
      native.dispose();
    },
  );
}
