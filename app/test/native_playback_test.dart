import 'dart:async';
import 'package:baha_plus/core/community.dart';
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
  final sources = <DataSource>[];
  final streams = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final released = <int>[];
  final playing = <int>{};

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    await holdCreation?.future;
    final id = sources.length;
    sources.add(options.dataSource);
    positions[id] = Duration.zero;
    streams[id] = StreamController<VideoEvent>()
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
    positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async => positions[playerId]!;
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
      await Future<void>.delayed(Duration.zero);
      expect(platform.released.length, platform.sources.length);
    },
  );

  test(
    'background activation stays paused and a policy rejection stops commands',
    () async {
      final native = create();
      await native.initialize(0);
      await native.activate(
        applicationActive: false,
        timeline: {'position': 30, 'paused': false, 'rate': 1, 'muted': false},
      );
      expect(native.state.paused, isTrue);
      await native.command('play', null);
      await native.block();
      expect(native.state.paused, isTrue);
      expect(native.state.phase.name, 'error');
      expect(await native.command('play', null), isFalse);
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
