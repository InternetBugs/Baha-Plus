import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/native_video_surface.dart';
import 'package:baha_plus/ui/official_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'core_test.dart' show FakeSearch, MemoryStorage;
import 'native_playback_test.dart' show FakeVideo, sourceJson;

class _HandoffWebViewPlatform extends InAppWebViewPlatform {
  final views = <_HandoffWebView>[];
  int disposals = 0;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _HandoffWebView(params, this);
    views.add(view);
    return view;
  }

  @override
  PlatformWebMessageListener createPlatformWebMessageListener(
    PlatformWebMessageListenerCreationParams params,
  ) => _HandoffMessageListener(params);
}

class _HandoffWebView extends PlatformInAppWebViewWidget {
  _HandoffWebView(super.params, this.owner) : super.implementation();

  final _HandoffWebViewPlatform owner;

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;

  @override
  void dispose() => owner.disposals++;
}

class _HandoffMessageListener extends PlatformWebMessageListener {
  _HandoffMessageListener(super.params) : super.implementation();
}

class _HandoffReplyProxy extends PlatformJavaScriptReplyProxy {
  _HandoffReplyProxy(PlatformWebMessageListener listener)
    : super.implementation(
        PlatformJavaScriptReplyProxyCreationParams(
          webMessageListener: listener,
        ),
      );
}

/// The actual OfficialBrowser host makes bridge calls against this controller.
/// Respond at the plugin boundary, without replacing its handoff or lifecycle
/// code. Page commands deliberately succeed so an accidental fallback fails
/// the routing assertions instead of being hidden by the fake.
class _HandoffController extends PlatformInAppWebViewController {
  _HandoffController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'handoff'),
      );

  late PlatformWebMessageListener listener;
  final loads = <URLRequest>[];
  final pageCommands = <Json>[];
  final clocks = <Json>[];
  final syncResults = Queue<FutureOr<CallAsyncJavaScriptResult?>>();
  WebUri? url;
  bool failNextPreparation = false;
  int reloads = 0, preparations = 0, commits = 0, failures = 0;

  @override
  Future<void> addWebMessageListener(
    PlatformWebMessageListener webMessageListener,
  ) async {
    listener = webMessageListener;
  }

  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {
    loads.add(urlRequest);
    url = urlRequest.url;
  }

  @override
  Future<void> reload() async => reloads++;

  @override
  Future<WebUri?> getUrl() async => url;

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> setSettings({required InAppWebViewSettings settings}) async {}

  @override
  Future<void> removeUserScriptsByGroupName({
    required String groupName,
  }) async {}

  @override
  Future<void> addUserScript({required UserScript userScript}) async {}

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => true;

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const {},
    ContentWorld? contentWorld,
  }) async {
    if (arguments.containsKey('action')) {
      pageCommands.add(Map<String, dynamic>.of(arguments));
      return CallAsyncJavaScriptResult(value: true);
    }
    if (functionBody.contains('.prepareNative()')) {
      preparations++;
      if (failNextPreparation) {
        failNextPreparation = false;
        return CallAsyncJavaScriptResult(value: jsonEncode(null));
      }
      return CallAsyncJavaScriptResult(
        value: jsonEncode({...sourceJson(), 'userAgent': 'handoff test agent'}),
      );
    }
    if (functionBody.contains('.commitNative()')) {
      commits++;
      return CallAsyncJavaScriptResult(
        value: jsonEncode({
          'position': 42,
          'paused': false,
          'rate': 1,
          'muted': false,
        }),
      );
    }
    if (arguments['clock'] case final Map<String, dynamic> clock) {
      clocks.add(Map<String, dynamic>.of(clock));
      return syncResults.isEmpty
          ? CallAsyncJavaScriptResult(value: 'ok')
          : await syncResults.removeFirst();
    }
    if (functionBody.contains('.failNative()')) {
      failures++;
      return CallAsyncJavaScriptResult(value: true);
    }
    if (functionBody.contains('.nativeDanmaku()')) {
      return CallAsyncJavaScriptResult(value: '[]');
    }
    throw StateError('Unexpected WebView async call in native handoff');
  }

  void publishContent(AppStore store) {
    listener.onPostMessage!(
      WebMessage(
        data: jsonEncode({
          'requestId': store.operation.id,
          'type': 'player-state',
          'id': '10',
          'videoId': '20',
          'phase': 'content',
          'surfaceReady': true,
          'paused': false,
          'buffering': false,
          'ended': false,
          'muted': false,
          'position': 37,
          'duration': 1200,
          'buffered': 90,
          'rate': 1,
          'qualities': [1080, 360],
          'quality': 0,
        }),
      ),
      WebUri(OfficialSite.home.toString()),
      true,
      _HandoffReplyProxy(listener),
    );
  }
}

class _HandoffVideo extends FakeVideo {
  bool failNextInitialization = false;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    if (failNextInitialization) {
      failNextInitialization = false;
      // Platform event channels stay open after errors and cancel
      // asynchronously. Complete cancellation in this test's fake async zone.
      final events = StreamController<VideoEvent>(onCancel: () async {});
      events.addError(
        PlatformException(
          code: 'native-initialization-failed',
          message:
              'The native player could not open the authorized HLS stream.',
        ),
      );
      addTearDown(events.close);
      return events.stream;
    }
    return super.videoEventsFor(playerId);
  }
}

class _Host {
  _Host(this.tester, this.store, this.webViews, this.controller, this.video);

  final WidgetTester tester;
  final AppStore store;
  final _HandoffWebViewPlatform webViews;
  final _HandoffController controller;
  final _HandoffVideo video;

  OfficialPortal get portal =>
      tester.state(find.byType(OfficialBrowser)) as OfficialPortal;
  NativePlayback get native => tester
      .widget<NativeVideoSurface>(find.byType(NativeVideoSurface))
      .playback;

  // These operations contain platform futures and permanent polling timers.
  // Flush frames explicitly instead of pumpAndSettle, which cannot settle a
  // playing video or a native handoff waiting for a deliberately held result.
  Future<void> flush() async {
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> waitFor(
    bool Function() observable, {
    required String reason,
  }) async {
    const frame = Duration(milliseconds: 20);
    const timeout = Duration(seconds: 3);
    var elapsed = Duration.zero;
    while (!observable() && elapsed < timeout) {
      await tester.pump(frame);
      elapsed += frame;
      expect(tester.takeException(), isNull);
    }
    expect(
      observable(),
      isTrue,
      reason:
          '$reason (waited ${elapsed.inMilliseconds}ms; '
          'playback phase: ${store.playback.value.phase.name})',
    );
    // The state can change in platform continuations after a frame's build.
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  Future<void> advance(Duration duration) async {
    await tester.pump(duration);
    await flush();
  }

  Future<void> content() async {
    controller.publishContent(store);
    await flush();
  }

  Future<void> backgroundRoundTrip() async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await flush();
    }
    expect(store.applicationActive, isTrue);
  }

  void expectSessionRetained(NativePlayback original, String document) {
    expect(identical(native, original), isTrue);
    expect(store.operation.id, document);
    expect(controller.loads, hasLength(1));
    expect(controller.reloads, 0);
    expect(controller.pageCommands, isEmpty);
    expect(webViews.views, hasLength(1));
    expect(webViews.disposals, 0);
    expect(video.sources, hasLength(1));
    expect(video.released, isEmpty);
  }
}

Future<_Host> _mountHost(
  WidgetTester tester, {
  bool failInitialization = false,
  Completer<void>? holdCreation,
}) async {
  tester.view.physicalSize = const Size(850, 450);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final previousWebViews = InAppWebViewPlatform.instance;
  final previousVideo = VideoPlayerPlatform.instance;
  final webViews = _HandoffWebViewPlatform();
  final controller = _HandoffController();
  final video = _HandoffVideo()
    ..failNextInitialization = failInitialization
    ..holdCreation = holdCreation;
  InAppWebViewPlatform.instance = webViews;
  VideoPlayerPlatform.instance = video;
  final store = (await tester.runAsync(
    () => AppStore.create(storage: MemoryStorage(), animeSearch: FakeSearch()),
  ))!;
  final host = _Host(tester, store, webViews, controller, video);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await host.flush();
    store.dispose();
    for (final stream in video.streams.values) {
      unawaited(stream.close());
    }
    if (previousWebViews != null) {
      InAppWebViewPlatform.instance = previousWebViews;
    }
    VideoPlayerPlatform.instance = previousVideo;
  });

  await store.play(
    const Anime(
      id: '10',
      title: 'Native handoff',
      cover: 'https://p2.bahamut.com.tw/10.jpg',
      latestVideoId: '20',
    ),
  );
  // Fullscreen avoids unrelated comment/catalog traffic while preserving the
  // actual AppRoot and OfficialBrowser lifecycle observers.
  store.setPlayerFullscreen(true);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      theme: GlassThemeData.simple(quality: GlassQuality.standard),
      child: BahaPlusApp(store: store),
    ),
  );
  expect(find.byType(OfficialBrowser), findsOneWidget);
  final view = webViews.views.single;
  final wrappedController = view.controllerFromPlatform<InAppWebViewController>(
    controller,
  );
  view.params.onWebViewCreated!(wrappedController);
  await host.flush();
  expect(
    controller.loads.single.url.toString(),
    OfficialSite.video('20').toString(),
  );
  view.params.onLoadStart!(wrappedController, controller.url);
  view.params.onPageCommitVisible!(wrappedController, controller.url);
  await host.flush();
  return host;
}

const _nativeHosts = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

void main() {
  testWidgets(
    'failed native initialization exposes retry and never dispatches content commands to the page',
    (tester) async {
      final host = await _mountHost(tester, failInitialization: true);
      await host.content();
      await host.waitFor(
        () => host.store.playback.value.phase == PlaybackPhase.error,
        reason: 'Failed native initialization must publish its retry state',
      );

      expect(host.store.usesNativePlayback, isTrue);
      expect(host.store.playback.value.phase, PlaybackPhase.error);
      expect(find.byType(NativeVideoSurface), findsNothing);
      expect(find.text(host.store.t('playerPlaybackError')), findsWidgets);
      expect(find.text(host.store.t('retry')), findsOneWidget);
      expect(host.controller.preparations, 1);
      expect(host.controller.commits, 0);
      expect(host.controller.failures, 1);
      expect(host.video.playCalls, isEmpty);
      expect(host.video.released, [0]);

      // Call the host directly: AppStore's disabled error controls must not be
      // the only protection against accidentally routing content to WebView.
      final failedDocument = host.store.operation.id;
      for (final (action, value) in <(String, double?)>[
        ('play', null),
        ('pause', null),
        ('seek', 43),
        ('rate', 1.5),
        ('mute', null),
        ('quality', 360),
      ]) {
        expect(
          await host.portal.playerCommand(failedDocument, action, value),
          isFalse,
          reason: '$action must not fall back to the page after native failure',
        );
      }
      expect(host.controller.pageCommands, isEmpty);
      expect(host.controller.reloads, 0);

      final retry = find.text(host.store.t('retry'));
      await host.waitFor(
        () => retry.hitTestable().evaluate().isNotEmpty,
        reason:
            'Initialization failure retry must be visible and accept pointer input',
      );
      await tester.tap(retry);
      await host.waitFor(
        () =>
            host.controller.reloads == 1 &&
            host.store.operation.id != failedDocument,
        reason: 'Explicit retry must reload a new playback document',
      );
      expect(host.controller.reloads, 1);
      expect(host.store.operation.id, isNot(failedDocument));
      await host.content();
      await host.waitFor(
        () =>
            host.store.usesNativePlayback &&
            host.store.playback.value.phase == PlaybackPhase.content &&
            find.byType(NativeVideoSurface).evaluate().length == 1,
        reason: 'Explicit retry must finish handing content to native playback',
      );
      expect(host.native.active, isTrue);
      expect(host.store.playback.value.phase, PlaybackPhase.content);
      expect(host.controller.commits, 1);
      expect(host.video.sources, hasLength(2));
      expect(host.video.playCalls, [1]);
      expect(host.controller.pageCommands, isEmpty);
    },
    variant: _nativeHosts,
  );

  testWidgets(
    'null native preparation exposes one retry without creating video or repeatedly preparing the page',
    (tester) async {
      final host = await _mountHost(tester);
      host.controller.failNextPreparation = true;
      final failedDocument = host.store.operation.id;
      await host.content();
      await host.waitFor(
        () => host.store.playback.value.phase == PlaybackPhase.error,
        reason: 'A null native source must publish an explicit retry state',
      );

      expect(host.store.usesNativePlayback, isTrue);
      expect(host.controller.failNextPreparation, isFalse);
      expect(host.controller.preparations, 1);
      expect(host.controller.failures, 1);
      expect(host.controller.commits, 0);
      expect(host.controller.clocks, isEmpty);
      expect(host.video.sources, isEmpty);
      expect(host.video.options, isEmpty);
      expect(host.video.streams, isEmpty);
      expect(host.video.playCalls, isEmpty);
      expect(host.video.released, isEmpty);
      expect(find.byType(NativeVideoSurface), findsNothing);
      expect(find.text(host.store.t('playerPlaybackError')), findsWidgets);
      final retry = find.text(host.store.t('retry'));
      expect(retry, findsOneWidget);
      await host.waitFor(
        () => retry.hitTestable().evaluate().isNotEmpty,
        reason: 'A null native source must leave retry visible and clickable',
      );

      // Real player-state heartbeats keep arriving every 500ms even when the
      // page has held its media for a failed source preparation.
      for (var heartbeat = 0; heartbeat < 4; heartbeat++) {
        await host.advance(const Duration(milliseconds: 500));
        await host.content();
        expect(host.store.playback.value.phase, PlaybackPhase.error);
        expect(host.controller.preparations, 1);
        expect(host.controller.failures, 1);
        expect(host.video.sources, isEmpty);
      }
      for (final (action, value) in <(String, double?)>[
        ('play', null),
        ('pause', null),
        ('seek', 43),
        ('rate', 1.5),
        ('mute', null),
        ('quality', 360),
      ]) {
        expect(
          await host.portal.playerCommand(failedDocument, action, value),
          isFalse,
          reason:
              '$action must not fall back to the held page after a null source',
        );
      }
      expect(host.controller.pageCommands, isEmpty);
      expect(host.controller.commits, 0);
      expect(host.controller.reloads, 0);
      expect(host.store.operation.id, failedDocument);

      await tester.tap(retry);
      await host.waitFor(
        () =>
            host.controller.reloads == 1 &&
            host.store.operation.id != failedDocument,
        reason: 'Retry after a null source must reload a new playback document',
      );
      await host.content();
      await host.waitFor(
        () =>
            host.store.usesNativePlayback &&
            host.store.playback.value.phase == PlaybackPhase.content &&
            find.byType(NativeVideoSurface).evaluate().length == 1,
        reason: 'Retry after a null source must complete native handoff',
      );
      expect(host.native.active, isTrue);
      expect(host.native.document, host.store.operation.id);
      expect(host.native.state.position, 42);
      expect(host.controller.preparations, 2);
      expect(host.controller.failures, 1);
      expect(host.controller.commits, 1);
      expect(host.controller.reloads, 1);
      expect(host.video.sources, hasLength(1));
      expect(host.video.playCalls, [0]);
      expect(host.controller.pageCommands, isEmpty);
      expect(retry, findsNothing);
      expect(host.webViews.views, hasLength(1));
      expect(host.webViews.disposals, 0);
    },
    variant: _nativeHosts,
  );

  testWidgets(
    'temporarily unavailable WebView clock recovers the same paused native session without reload',
    (tester) async {
      final host = await _mountHost(tester);
      await host.content();
      final original = host.native;
      final document = host.store.operation.id;
      expect(original.state.paused, isFalse);
      expect(host.video.playCalls, [0]);
      expect(host.controller.clocks, hasLength(1));

      host.controller.syncResults.add(
        CallAsyncJavaScriptResult(value: 'unavailable'),
      );
      await host.advance(const Duration(seconds: 1));
      expect(original.authorizationAvailable, isFalse);
      expect(original.state.phase, PlaybackPhase.error);
      expect(original.state.paused, isTrue);
      expect(find.text(host.store.t('retry')), findsOneWidget);
      expect(await host.portal.playerCommand(document, 'play', null), isFalse);
      host.expectSessionRetained(original, document);

      await host.advance(const Duration(seconds: 1));
      expect(host.controller.clocks, hasLength(3));
      expect(original.authorizationAvailable, isTrue);
      expect(original.state.phase, PlaybackPhase.content);
      expect(original.state.paused, isTrue);
      expect(original.state.position, 42);
      expect(find.text(host.store.t('retry')), findsNothing);
      expect(host.video.playCalls, [
        0,
      ], reason: 'Recovery must preserve pause intent');
      host.expectSessionRetained(original, document);

      await host.store.controlPlayer('seek', 43);
      await host.store.controlPlayer('play');
      await host.flush();
      expect(original.state.position, 43);
      expect(original.state.paused, isFalse);
      expect(host.video.playCalls, [0, 0]);
      host.expectSessionRetained(original, document);
    },
    variant: _nativeHosts,
  );

  testWidgets(
    'denied clock reply from before a screen lock cannot permanently block the resumed native session',
    (tester) async {
      final host = await _mountHost(tester);
      await host.content();
      final original = host.native;
      final document = host.store.operation.id;
      final lateReply = Completer<CallAsyncJavaScriptResult?>();
      host.controller.syncResults.add(lateReply.future);
      await host.advance(const Duration(seconds: 1));
      expect(host.controller.clocks, hasLength(2));

      await host.backgroundRoundTrip();
      expect(original.state.paused, isTrue);
      expect(host.video.playCalls, [0]);
      lateReply.complete(CallAsyncJavaScriptResult(value: 'denied'));
      await host.flush();
      expect(original.state.phase, PlaybackPhase.content);
      expect(original.authorizationAvailable, isTrue);
      expect(original.state.paused, isTrue);
      host.expectSessionRetained(original, document);

      await host.advance(const Duration(seconds: 6));
      expect(host.controller.clocks.length, greaterThan(2));
      expect(original.state.phase, PlaybackPhase.content);
      expect(host.video.playCalls, [0]);
      expect(
        await host.portal.playerCommand(document, 'play', null),
        isTrue,
        reason:
            'A stale denied reply must not irreversibly block NativePlayback',
      );
      await host.flush();
      expect(original.state.paused, isFalse);
      expect(host.video.playCalls, [0, 0]);
      host.expectSessionRetained(original, document);
    },
    variant: _nativeHosts,
  );

  testWidgets(
    'native creation completing after a screen lock round trip hands off paused',
    (tester) async {
      final creation = Completer<void>();
      final host = await _mountHost(tester, holdCreation: creation);
      final document = host.store.operation.id;
      await host.content();
      expect(host.controller.preparations, 1);
      expect(host.controller.commits, 0);
      expect(host.store.usesNativePlayback, isTrue);
      expect(host.video.sources, isEmpty);

      await host.backgroundRoundTrip();
      creation.complete();
      await host.flush();
      final native = host.native;
      expect(native.active, isTrue);
      expect(native.state.phase, PlaybackPhase.content);
      expect(native.state.position, 42);
      expect(native.state.paused, isTrue);
      expect(host.controller.commits, 1);
      expect(host.video.playCalls, isEmpty);
      host.expectSessionRetained(native, document);

      expect(await host.portal.playerCommand(document, 'play', null), isTrue);
      await host.flush();
      expect(host.video.playCalls, [0]);
      expect(native.state.paused, isFalse);
      host.expectSessionRetained(native, document);
    },
    variant: _nativeHosts,
  );

  testWidgets(
    'native decoder errors recover with the last content checkpoint',
    (tester) async {
      final host = await _mountHost(tester);
      await host.content();
      final document = host.store.operation.id;
      host.video.streams[0]!.addError(
        PlatformException(
          code: 'decoder-disconnected',
          message: 'The decoder is unavailable',
        ),
      );
      await host.flush();
      expect(host.store.playback.value.phase, PlaybackPhase.error);
      await host.advance(const Duration(seconds: 3));
      expect(host.store.operation.id, isNot(document));
      expect(host.controller.loads, hasLength(2));
      expect(
        Uri.parse(
          host.controller.loads.last.url.toString(),
        ).queryParameters['t'],
        '42',
      );
      expect(host.video.released, [0]);
      await host.content();
      expect(host.store.playback.value.phase, PlaybackPhase.content);
      expect(host.video.playCalls, [0, 1]);
    },
    variant: _nativeHosts,
  );

  testWidgets(
    'paused native content waits for explicit retry after process termination',
    (tester) async {
      final host = await _mountHost(tester);
      await host.content();
      await host.store.controlPlayer('pause');
      await host.flush();
      final document = host.store.operation.id;
      final view = host.webViews.views.single;
      final controller = view.controllerFromPlatform<InAppWebViewController>(
        host.controller,
      );
      view.params.onWebContentProcessDidTerminate!(controller);
      await host.advance(const Duration(seconds: 35));
      expect(host.store.operation.id, document);
      expect(host.controller.loads, hasLength(1));
      expect(host.store.playback.value.phase, PlaybackPhase.error);
      expect(host.native.state.paused, isTrue);
    },
    variant: _nativeHosts,
  );

  testWidgets(
    'Android renderer loss recreates the WebView and rejects the old instance',
    (tester) async {
      final host = await _mountHost(tester);
      await host.content();
      final oldView = host.webViews.views.single;
      final oldController = oldView
          .controllerFromPlatform<InAppWebViewController>(host.controller);
      expect(oldView.params.initialSettings!.useOnRenderProcessGone, isTrue);
      oldView.params.onRenderProcessGone!(
        oldController,
        RenderProcessGoneDetail(didCrash: false),
      );
      await host.flush();
      expect(host.webViews.views, hasLength(2));
      expect(host.webViews.disposals, 1);
      final replacement = _HandoffController();
      final view = host.webViews.views.last;
      final controller = view.controllerFromPlatform<InAppWebViewController>(
        replacement,
      );
      view.params.onWebViewCreated!(controller);
      await host.flush();
      expect(replacement.loads, hasLength(1));
      expect(
        Uri.parse(replacement.loads.single.url.toString()).queryParameters['t'],
        '42',
      );
      view.params.onLoadStart!(controller, replacement.url);
      view.params.onPageCommitVisible!(controller, replacement.url);
      await host.flush();
      final recoveredDocument = host.store.operation.id;
      host.controller.publishContent(host.store);
      oldView.params.onWebContentProcessDidTerminate!(oldController);
      oldView.params.onLoadStop!(oldController, host.controller.url);
      await host.flush();
      expect(host.store.operation.id, recoveredDocument);
      expect(replacement.preparations, 0);
      replacement.publishContent(host.store);
      await host.flush();
      expect(host.store.playback.value.phase, PlaybackPhase.content);
      expect(replacement.commits, 1);
      expect(host.video.sources, hasLength(2));
      expect(host.video.released, [0]);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'WebContent termination reloads once and restores native content',
    (tester) async {
      final host = await _mountHost(tester);
      await host.content();
      final original = host.native;
      final document = host.store.operation.id;
      expect(original.state.paused, isFalse);
      final view = host.webViews.views.single;
      final controller = view.controllerFromPlatform<InAppWebViewController>(
        host.controller,
      );

      view.params.onWebContentProcessDidTerminate!(controller);
      await host.flush();
      // WebKit can report the same terminated document more than once.
      view.params.onWebContentProcessDidTerminate!(controller);
      await host.advance(const Duration(seconds: 6));

      expect(host.store.operation.id, isNot(document));
      expect(host.controller.loads, hasLength(2));
      expect(
        Uri.parse(
          host.controller.loads.last.url.toString(),
        ).queryParameters['t'],
        '42',
      );
      expect(host.store.playback.value.phase, PlaybackPhase.loading);
      expect(host.video.released, [0]);
      expect(host.video.playCalls, [0]);
      expect(await host.portal.playerCommand(document, 'play', null), isFalse);
      expect(find.byType(NativeVideoSurface), findsNothing);
      expect(host.webViews.views, hasLength(1));
      expect(original.active, isFalse);
      await host.content();
      await host.waitFor(
        () => host.store.playback.value.phase == PlaybackPhase.content,
        reason: 'Recovery must complete the new native handoff',
      );
      expect(host.video.sources, hasLength(2));
      expect(host.video.playCalls, [0, 1]);
      expect(host.controller.loads, hasLength(2));
    },
    variant: _nativeHosts,
  );
}
