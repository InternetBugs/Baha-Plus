import 'dart:async';
import 'dart:io';

import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/native_hls_cache.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'native_hls_cache_test.dart' show media, mediaUris;
import 'native_playback_test.dart' show FakeVideo, sourceJson;

// Flutter's widget binding blocks HTTP by default. This client reaches only
// the real loopback server; the upstream CDN is still a MockClient.
class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late http.Client local;
  late FakeVideo platform;
  late NativePlayback native;
  late List<PlaybackState> states;
  late int transfers;
  late bool offline;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'baha-cache-player-test-',
    );
    local = IOClient(
      _LoopbackHttpOverrides().createHttpClient(null)
        ..findProxy = (_) => 'DIRECT',
    );
    platform = FakeVideo();
    VideoPlayerPlatform.instance = platform;
    states = [];
    transfers = 0;
    offline = false;
    native = NativePlayback(
      document: 'current',
      source: NativePlaybackSource.fromJson(sourceJson()),
      userAgent: 'test-device',
      onState: states.add,
      cacheFactory: () => NativeHlsCache(
        headers: const {},
        createDirectory: () async => directory,
        client: MockClient((request) async {
          transfers++;
          if (offline) throw const SocketException('offline');
          return http.Response(
            request.url.path.endsWith('.m3u8') ? media : 'cached-segment',
            200,
          );
        }),
      ),
    );
  });

  tearDown(() async {
    local.close();
    native.dispose();
    await native.released;
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> initialize() async {
    await native.initialize(0);
    await native.activate(
      applicationActive: true,
      timeline: {'position': 10, 'paused': false, 'rate': 1, 'muted': false},
    );
  }

  test(
    'an empty AVPlayer buffer after background preserves playable disk ranges',
    () async {
      await initialize();
      final source = Uri.parse(platform.sources.single.uri!);
      expect(source.host, '127.0.0.1');
      expect(platform.sources.single.httpHeaders, isEmpty);
      final parts = mediaUris(await local.read(source));
      await local.read(parts[0]);
      await local.read(parts[2]);
      platform.streams[0]!.add(
        VideoEvent(
          eventType: VideoEventType.bufferingUpdate,
          buffered: [DurationRange(Duration.zero, const Duration(seconds: 30))],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(native.state.bufferRanges, [(start: 0.0, end: 30.0)]);
      await native.setApplicationActive(false);
      platform.streams[0]!.add(
        VideoEvent(eventType: VideoEventType.bufferingUpdate, buffered: []),
      );
      await Future<void>.delayed(Duration.zero);
      await native.setApplicationActive(true);
      expect(native.state.paused, isTrue);
      expect(native.state.position, 10);
      expect(states.last.bufferRanges, [
        (start: 0.0, end: 10.0),
        (start: 20.0, end: 30.0),
      ]);
      expect(native.state.buffered, 30);
      expect(platform.sources, hasLength(1));
      expect(platform.released, isEmpty);
      final count = transfers;
      offline = true;
      expect(await native.command('play', null), isTrue);
      expect(await local.read(parts[0]), 'cached-segment');
      expect(await local.read(parts[2]), 'cached-segment');
      expect(transfers, count);
      expect(native.state.paused, isFalse);
    },
  );

  test(
    'quality changes isolate ranges and reuse cached data when returning',
    () async {
      await initialize();
      final original = Uri.parse(platform.sources.single.uri!);
      final parts = mediaUris(await local.read(original));
      await local.read(parts[0]);
      expect(native.state.bufferRanges, [(start: 0.0, end: 10.0)]);
      expect(await native.command('quality', 1080), isTrue);
      expect(native.state.bufferRanges, isEmpty);
      expect(Uri.parse(platform.sources.last.uri!), isNot(original));
      expect(await native.command('quality', 0), isTrue);
      expect(Uri.parse(platform.sources.last.uri!), original);
      expect(native.state.bufferRanges, [(start: 0.0, end: 10.0)]);
      final count = transfers;
      offline = true;
      expect(await local.read(parts[0]), 'cached-segment');
      expect(transfers, count);
    },
  );

  test(
    'a pending quality change cannot resume after a background round trip',
    () async {
      await initialize();
      final original = Uri.parse(platform.sources.single.uri!);
      final parts = mediaUris(await local.read(original));
      await local.read(parts[0]);
      final held = platform.holdCreation = Completer<void>();
      final changing = native.command('quality', 1080);
      await Future<void>.delayed(Duration.zero);
      await native.setApplicationActive(false);
      await native.setApplicationActive(true);
      held.complete();
      expect(await changing, isTrue);
      expect(native.state.paused, isTrue);
      expect(native.state.bufferRanges, isEmpty);
      expect(await native.command('quality', 0), isTrue);
      expect(native.state.bufferRanges, [(start: 0.0, end: 10.0)]);
      expect(native.state.paused, isTrue);
    },
  );

  test(
    'exiting during cache initialization releases the late directory',
    () async {
      native.dispose();
      await native.released;
      final pendingDirectory = Completer<Directory>();
      native = NativePlayback(
        document: 'closing',
        source: NativePlaybackSource.fromJson(sourceJson()),
        userAgent: 'test-device',
        onState: states.add,
        cacheFactory: () => NativeHlsCache(
          headers: const {},
          createDirectory: () => pendingDirectory.future,
          client: MockClient(
            (_) async => throw StateError('No download expected'),
          ),
        ),
      );
      final initializing = native.initialize(0);
      native.dispose();
      pendingDirectory.complete(directory);
      await initializing;
      await native.released;
      expect(platform.sources, isEmpty);
      expect(await directory.exists(), isFalse);
    },
  );

  test(
    'unavailable temporary storage still permits direct native playback',
    () async {
      native.dispose();
      await native.released;
      native = NativePlayback(
        document: 'no-storage',
        source: NativePlaybackSource.fromJson(sourceJson()),
        userAgent: 'test-device',
        onState: states.add,
        cacheFactory: () => NativeHlsCache(
          headers: const {},
          createDirectory: () async => throw const FileSystemException(),
        ),
      );
      await initialize();
      expect(platform.sources.single.uri, sourceJson()['master']);
      expect(native.state.phase, PlaybackPhase.content);
      expect(native.state.paused, isFalse);
    },
  );

  test('released waits for both decoder and session cache cleanup', () async {
    await initialize();
    final original = Uri.parse(platform.sources.single.uri!);
    final parts = mediaUris(await local.read(original));
    await local.read(parts[0]);
    native.dispose();
    await native.released;
    expect(platform.released, [0]);
    expect(await directory.exists(), isFalse);
    await expectLater(
      local.get(parts[0]),
      throwsA(isA<http.ClientException>()),
    );
  });
}
