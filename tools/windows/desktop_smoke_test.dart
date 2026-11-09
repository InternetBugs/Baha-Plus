import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/desktop_main.dart' as desktop;
import 'package:baha_plus/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows mpv decodes local HLS and handles seek, pause and lifecycle',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      expect(AppStore.nativePlaybackBackend, 'windows-mpv');
      VideoPlayerMediaKit.ensureInitialized(windows: true);
      expect(
        VideoPlayerPlatform.instance.runtimeType.toString(),
        'MediaKitVideoPlayer',
      );

      final fixture = await _LocalHlsFixture.open();
      addTearDown(fixture.close);
      final controller = VideoPlayerController.networkUrl(
        fixture.uri,
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: false,
          allowBackgroundPlayback: true,
          preventsDisplaySleepDuringVideoPlayback: false,
        ),
      );
      var disposed = false;
      addTearDown(() async {
        // Restore frames even when an assertion fails in the background phase.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        try {
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          if (!disposed) {
            await controller.dispose().timeout(const Duration(seconds: 10));
          }
        }
      });

      _trace('initialize', {'url': fixture.uri.toString()});
      await _initializeWithFrames(tester, controller);
      expect(controller.value.isInitialized, isTrue);
      expect(controller.value.hasError, isFalse);
      expect(controller.value.size, const Size(256, 144));
      expect(controller.value.duration.inMilliseconds, closeTo(8000, 400));
      final playerId = controller.playerId;
      expect(playerId, isNot(VideoPlayerController.kUninitializedPlayerId));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 512,
                height: 288,
                child: VideoPlayer(controller),
              ),
            ),
          ),
        ),
      );
      await controller.play().timeout(const Duration(seconds: 5));
      final firstPosition = await _waitForPosition(
        tester,
        controller,
        'initial playback',
        (position) => position >= const Duration(milliseconds: 600),
      );

      // A real output texture larger than the initial 1px surface is required.
      // Metadata or the Dart controller's optimistic play state is insufficient.
      final videoTexture = find.descendant(
        of: find.byType(VideoPlayer),
        matching: find.byType(Texture),
      );
      bool hasVideoTexture() {
        if (videoTexture.evaluate().length != 1) return false;
        final size = tester.getSize(videoTexture);
        return size.width > 1 && size.height > 1;
      }

      final textureDeadline = Stopwatch()..start();
      while (!hasVideoTexture() &&
          textureDeadline.elapsed < const Duration(seconds: 10)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(videoTexture, findsOneWidget);
      final textureSize = tester.getSize(videoTexture);
      expect(textureSize.width, greaterThan(1));
      expect(textureSize.height, greaterThan(1));
      expect(fixture.servedPaths, containsAll(['/index.m3u8', '/init.mp4']));
      expect(fixture.servedPaths.any((path) => path.endsWith('.m4s')), isTrue);
      _trace('decoded', {
        'playerId': playerId,
        'width': controller.value.size.width,
        'height': controller.value.size.height,
        'textureId': tester.widget<Texture>(videoTexture).textureId,
        'positionMs': firstPosition.inMilliseconds,
        'bytesServed': fixture.bytesServed,
      });

      await controller.pause().timeout(const Duration(seconds: 5));
      final paused = await _nativePosition(controller);
      await tester.pump(const Duration(milliseconds: 800));
      final stillPaused = await _nativePosition(controller);
      expect(controller.value.isPlaying, isFalse);
      _expectStationary(paused, stillPaused, 'pause');
      _trace('paused', {'positionMs': stillPaused.inMilliseconds});

      const seekTarget = Duration(seconds: 4);
      await controller.seekTo(seekTarget).timeout(const Duration(seconds: 5));
      // Read the plugin's native clock: seekTo also updates value.position
      // optimistically, so that value alone cannot prove a successful seek.
      final sought = await _waitForPosition(
        tester,
        controller,
        'paused seek to 4 seconds',
        (position) => (position - seekTarget).inMilliseconds.abs() <= 400,
      );
      expect(controller.value.isPlaying, isFalse);
      await tester.pump(const Duration(milliseconds: 600));
      _expectStationary(
        sought,
        await _nativePosition(controller),
        'paused seek',
      );
      _trace('seeked', {'positionMs': sought.inMilliseconds});

      await controller.play().timeout(const Duration(seconds: 5));
      await _waitForPosition(
        tester,
        controller,
        'play after seek',
        (position) => position >= sought + const Duration(milliseconds: 600),
      );

      // The host explicitly pauses, matching the application's pause intent.
      // These are synthetic Flutter notifications, not an OS minimize test.
      await controller.pause().timeout(const Duration(seconds: 5));
      final beforeLifecycle = await _nativePosition(controller);
      try {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          binding.handleAppLifecycleStateChanged(state);
        }
        // Hidden/paused disables frames; pumping here would wait indefinitely.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(controller.value.isPlaying, isFalse);
        _expectStationary(
          beforeLifecycle,
          await _nativePosition(controller),
          'background after explicit pause',
        );
      } finally {
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          binding.handleAppLifecycleStateChanged(state);
        }
      }
      await tester.pump(const Duration(milliseconds: 700));
      expect(controller.value.isInitialized, isTrue);
      expect(controller.value.isPlaying, isFalse);
      expect(controller.playerId, playerId);
      final afterLifecycle = await _nativePosition(controller);
      _expectStationary(beforeLifecycle, afterLifecycle, 'foreground return');
      _trace('lifecycle-paused', {
        'syntheticNotifications': true,
        'hostPausedBeforeBackground': true,
        'playerId': controller.playerId,
        'positionMs': afterLifecycle.inMilliseconds,
      });

      await controller.play().timeout(const Duration(seconds: 5));
      await _waitForPosition(
        tester,
        controller,
        'explicit play after lifecycle',
        (position) =>
            position >= afterLifecycle + const Duration(milliseconds: 500),
      );
      await controller.pause().timeout(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose().timeout(const Duration(seconds: 10));
      disposed = true;
      expect(await controller.position, isNull);
      expect(tester.takeException(), isNull);
      _trace('disposed', {
        'playerId': playerId,
        'servedPaths': fixture.servedPaths.toList()..sort(),
        'bytesServed': fixture.bytesServed,
        'httpErrors': fixture.errors,
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('desktop launches the current app and switches all native tabs', (
    tester,
  ) async {
    AppStore? store;
    final portal = find.byType(InAppWebView, skipOffstage: false);
    final portalTexture = find.descendant(
      of: portal,
      matching: find.byType(Texture, skipOffstage: false),
      skipOffstage: false,
    );
    addTearDown(() async {
      try {
        // Unmount the portal and animation owners before disposing the store.
        await _pumpDesktopWidget(tester, const SizedBox.shrink());
        await _pumpDesktopFrame(tester);
        expect(portal, findsNothing);
        expect(portalTexture, findsNothing);
        await desktop.shutdownNativeDesktopViews();
        await desktop.shutdownNativeDesktopViews();
      } finally {
        store?.dispose();
      }
    });
    await desktop.main().timeout(const Duration(seconds: 45));
    await _waitForDesktopApp(tester, portalTexture);
    expect(find.byType(BahaPlusApp), findsOneWidget);
    expect(AppStore.nativePlaybackBackend, 'windows-mpv');
    final appStore = tester.widget<BahaPlusApp>(find.byType(BahaPlusApp)).store;
    store = appStore;
    for (final tab in [1, 2, 3, 4, 0]) {
      final hiddenFrame = tab == 3;
      if (hiddenFrame) {
        // Reproduce the disabled-frame condition that previously left a
        // normal pump waiting forever when the desktop window was hidden.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        expect(binding.framesEnabled, isFalse);
      }
      try {
        appStore.selectTab(tab);
        await _pumpDesktopFrame(tester);
      } finally {
        if (hiddenFrame) {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
      }
      // Establish a real engine timestamp after the hidden warm-up frame.
      if (hiddenFrame) await _pumpDesktopFrame(tester);
      await _pumpDesktopFrame(
        tester,
        elapsed: const Duration(milliseconds: 500),
      );
      expect(appStore.tab, tab);
      expect(find.byKey(PageStorageKey('catalog-tab-$tab')), findsOneWidget);
      final transition = tester.widget<Transform>(
        find.byKey(const ValueKey('tab-page-transition')),
      );
      expect(transition.transform.storage[12], closeTo(0, .1));
      expect(tester.takeException(), isNull);
    }
    expect(find.byType(MaterialApp), findsOneWidget);
    _trace('app-tabs', {
      'tabs': [1, 2, 3, 4, 0],
      'syntheticHiddenFrames': true,
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _waitForDesktopApp(
  WidgetTester tester,
  Finder portalTexture,
) async {
  final binding = tester.binding;
  final previousFrame = binding.currentSystemFrameTimeStamp.inMicroseconds;
  int? firstAppFrame;
  var lastRasterizedFrame = -1;
  void recordTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final stamp = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      if (stamp > lastRasterizedFrame) lastRasterizedFrame = stamp;
    }
  }

  final elapsed = Stopwatch()..start();
  const budget = Duration(seconds: 90);
  binding.addTimingsCallback(recordTimings);
  try {
    while (elapsed.elapsed < budget) {
      await _pumpDesktopFrame(
        tester,
        elapsed: const Duration(milliseconds: 100),
        timeout: budget - elapsed.elapsed,
      );
      final stamp = binding.currentSystemFrameTimeStamp.inMicroseconds;
      if (stamp > previousFrame) firstAppFrame ??= stamp;
      final rasterReady =
          firstAppFrame != null && lastRasterizedFrame >= firstAppFrame;
      if (portalTexture.evaluate().length == 1 && rasterReady) {
        _trace('app-ready', {
          'elapsedMs': elapsed.elapsedMilliseconds,
          'webViewTextureId': tester.widget<Texture>(portalTexture).textureId,
          'appFrameVsyncMicros': firstAppFrame,
          'rasterizedFrameVsyncMicros': lastRasterizedFrame,
        });
        return;
      }
    }
    fail(
      'Desktop readiness timed out: nativeTextures='
      '${portalTexture.evaluate().length}, '
      'appFrame=$firstAppFrame, rasterizedFrame=$lastRasterizedFrame.',
    );
  } finally {
    binding.removeTimingsCallback(recordTimings);
  }
}

Future<void> _pumpDesktopFrame(
  WidgetTester tester, {
  Duration elapsed = Duration.zero,
  Duration timeout = const Duration(seconds: 15),
}) async {
  // LiveTestWidgetsFlutterBinding.pump waits for a platform frame. A real
  // hidden/minimized window disables that request, including during teardown.
  // Keep normal platform/raster pacing while visible. Only rescue a pending
  // pump with a warm-up frame if the lifecycle disables frames, including if
  // it changes after pump starts. OS minimize/exit is tested separately.
  if (elapsed > Duration.zero) await Future<void>.delayed(elapsed);
  await _finishDesktopPump(tester, tester.pump(), timeout: timeout);
}

Future<void> _pumpDesktopWidget(WidgetTester tester, Widget widget) async {
  await _finishDesktopPump(
    tester,
    tester.pumpWidget(widget),
    forceWarmUp: true,
  );
}

Future<void> _finishDesktopPump(
  WidgetTester tester,
  Future<void> pending, {
  Duration timeout = const Duration(seconds: 15),
  bool forceWarmUp = false,
}) async {
  void rescueHiddenFrame() {
    if (!tester.binding.framesEnabled) {
      tester.binding.scheduleWarmUpFrame();
    }
  }

  if (forceWarmUp) {
    tester.binding.scheduleWarmUpFrame();
  } else {
    rescueHiddenFrame();
  }
  var expired = false;
  final deadline = Timer(timeout, () {
    expired = true;
    // Settle the guarded pump before reporting a timeout, so teardown can run.
    tester.binding.scheduleWarmUpFrame();
  });
  final rescue = Timer.periodic(
    const Duration(milliseconds: 16),
    (_) => rescueHiddenFrame(),
  );
  try {
    await pending;
    if (expired) {
      throw TimeoutException('Desktop frame did not arrive', timeout);
    }
  } finally {
    deadline.cancel();
    rescue.cancel();
  }
}

Future<void> _initializeWithFrames(
  WidgetTester tester,
  VideoPlayerController controller,
) async {
  const timeout = Duration(seconds: 30);
  final elapsed = Stopwatch()..start();
  var completed = false;
  var pumpedFrames = 0;
  Object? initializationError;
  StackTrace? initializationStack;

  // media_kit_video creates its native controller in a post-frame callback.
  // Keep frames flowing while initialize waits for that controller and media.
  // Observe errors immediately so they remain handled while a pump is pending.
  unawaited(
    controller.initialize().then<void>(
      (_) {
        completed = true;
      },
      onError: (Object error, StackTrace stack) {
        initializationError = error;
        initializationStack = stack;
        completed = true;
      },
    ),
  );
  while (!completed && elapsed.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 100));
    pumpedFrames++;
  }
  if (!completed) {
    throw TimeoutException(
      'Windows mpv initialization did not complete while pumping frames.',
      timeout,
    );
  }
  final error = initializationError;
  if (error != null) {
    Error.throwWithStackTrace(error, initializationStack!);
  }
  _trace('initialized', {
    'elapsedMs': elapsed.elapsedMilliseconds,
    'pumpedFrames': pumpedFrames,
  });
}

Future<Duration> _nativePosition(VideoPlayerController controller) async {
  expect(
    controller.value.hasError,
    isFalse,
    reason: controller.value.errorDescription,
  );
  final position = await controller.position.timeout(
    const Duration(seconds: 3),
  );
  if (position == null) fail('Native player returned no playback position.');
  return position;
}

Future<Duration> _waitForPosition(
  WidgetTester tester,
  VideoPlayerController controller,
  String stage,
  bool Function(Duration position) ready,
) async {
  final elapsed = Stopwatch()..start();
  var position = Duration.zero;
  while (elapsed.elapsed < const Duration(seconds: 12)) {
    position = await _nativePosition(controller);
    if (ready(position)) return position;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail(
    '$stage timed out: native=${position.inMilliseconds}ms, '
    'playing=${controller.value.isPlaying}, '
    'buffering=${controller.value.isBuffering}.',
  );
}

void _expectStationary(Duration before, Duration after, String stage) {
  expect(
    (after - before).inMilliseconds.abs(),
    lessThanOrEqualTo(300),
    reason: '$stage must preserve the native playback position.',
  );
}

void _trace(String stage, Map<String, Object?> fields) {
  debugPrint('[BAHA_WINDOWS_SMOKE] ${jsonEncode({'stage': stage, ...fields})}');
}

class _LocalHlsFixture {
  _LocalHlsFixture(this.server, this.files);

  final HttpServer server;
  final Map<String, Uint8List> files;
  final servedPaths = <String>{};
  final errors = <String>[];
  var bytesServed = 0;
  StreamSubscription<HttpRequest>? _requests;

  Uri get uri => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: '/index.m3u8',
  );

  static Future<_LocalHlsFixture> open() async {
    const definedDirectory = String.fromEnvironment('BAHA_DESKTOP_FIXTURE');
    final path = definedDirectory.isNotEmpty
        ? definedDirectory
        : Platform.environment['BAHA_DESKTOP_FIXTURE'];
    if (path == null || path.trim().isEmpty) {
      fail(
        'Set BAHA_DESKTOP_FIXTURE (environment or --dart-define) to the '
        'absolute artifacts/windows-debug/fixtures directory containing '
        'the original 8-second H.264 HLS fixture.',
      );
    }
    final directory = Directory(path).absolute;
    final files = <String, Uint8List>{};
    for (final name in [
      'index.m3u8',
      'init.mp4',
      for (var index = 0; index < 4; index++)
        'segment-${index.toString().padLeft(2, '0')}.m4s',
    ]) {
      final file = File.fromUri(directory.uri.resolve(name));
      if (!await file.exists()) fail('Missing local HLS fixture: ${file.path}');
      files['/$name'] = await file.readAsBytes();
    }
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    ).timeout(const Duration(seconds: 5));
    final fixture = _LocalHlsFixture(server, files);
    fixture._requests = server.listen(
      (request) => unawaited(fixture._serve(request)),
      onError: (Object error) => fixture.errors.add(error.toString()),
    );
    _trace('fixture-ready', {
      'directory': directory.path,
      'url': fixture.uri.toString(),
    });
    return fixture;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    response.persistentConnection = false;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final bytes = files[request.uri.path];
      if (bytes == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      response.headers.contentType = request.uri.path.endsWith('.m3u8')
          ? ContentType('application', 'vnd.apple.mpegurl')
          : ContentType('video', 'mp4');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      var start = 0;
      var end = bytes.length - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        start = match == null ? -1 : int.tryParse(match.group(1)!) ?? -1;
        final requestedEnd = match?.group(2) ?? '';
        if (requestedEnd.isNotEmpty) {
          end = int.tryParse(requestedEnd) ?? -1;
          if (end >= bytes.length) end = bytes.length - 1;
        }
        if (start < 0 || start >= bytes.length || end < start) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${bytes.length}',
          );
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
      }
      response.contentLength = end - start + 1;
      if (request.method == 'GET') {
        response.add(Uint8List.sublistView(bytes, start, end + 1));
        servedPaths.add(request.uri.path);
        bytesServed += end - start + 1;
      }
    } catch (error) {
      errors.add(error.toString());
    } finally {
      try {
        await response.close();
      } catch (error) {
        // mpv may abandon a buffered request when seeking or disposing.
        errors.add(error.toString());
      }
    }
  }

  Future<void> close() async {
    try {
      // Force closes active and keep-alive sockets, including failed tests.
      await server.close(force: true).timeout(const Duration(seconds: 5));
    } finally {
      await _requests?.cancel();
    }
  }
}
