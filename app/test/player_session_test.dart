import 'dart:ui' as ui;

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/comments_page.dart';
import 'package:baha_plus/ui/danmaku_panel.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'community_test.dart' show commentJson, commentPageJson;

class _RecordingWebViewPlatform extends InAppWebViewPlatform {
  final views = <_RecordingWebView>[];
  int mounts = 0, disposals = 0;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _RecordingWebView(params, this);
    views.add(view);
    return view;
  }
}

class _RecordingWebView extends PlatformInAppWebViewWidget {
  _RecordingWebView(super.params, this.owner) : super.implementation();
  final _RecordingWebViewPlatform owner;

  @override
  Widget build(BuildContext context) => _VideoSurface(owner: owner);

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() => owner.disposals++;
}

class _VideoSurface extends StatefulWidget {
  const _VideoSurface({required this.owner});
  final _RecordingWebViewPlatform owner;

  @override
  State<_VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<_VideoSurface> {
  @override
  void initState() {
    super.initState();
    widget.owner.mounts++;
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

class _SessionPortal extends FakePortal {
  int reloads = 0;

  @override
  Future<void> reload() async => reloads++;
}

void main() {
  testWidgets(
    'player menus, app switching and screen lock preserve the WebView session',
    (tester) async {
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final previousPlatform = InAppWebViewPlatform.instance;
      final platform = _RecordingWebViewPlatform();
      InAppWebViewPlatform.instance = platform;
      addTearDown(() {
        if (previousPlatform != null) {
          InAppWebViewPlatform.instance = previousPlatform;
        }
      });
      final store = (await tester.runAsync(
        () => AppStore.create(
          storage: MemoryStorage(),
          animeSearch: FakeSearch(),
        ),
      ))!;
      addTearDown(store.dispose);
      final portal = _SessionPortal()
        ..communityResponse = {
          'ok': true,
          'messageId': '123',
          'total': 0,
          'nextPage': 0,
          'comments': <Json>[],
        };
      await store.attach(portal);
      await store.play(
        const Anime(
          id: '10',
          title: 'Test Anime',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
          latestVideoId: '20',
        ),
      );
      store.playerDetail = AnimeDetail.fromJson({
        'title': 'Test Anime',
        'description': List.filled(210, '介').join(),
        'episodes': [
          {'id': '20', 'label': '1'},
        ],
        'metadata': <Json>[],
      });
      const playback = PlaybackState(
        phase: PlaybackPhase.content,
        surfaceReady: true,
        paused: false,
        buffering: false,
        position: 37,
        duration: 1200,
        buffered: 90,
        qualities: [720, 360],
        hasDanmaku: true,
      );
      store.playback.value = playback;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: BahaPlusApp(store: store),
        ),
      );

      Future<void> frames() async {
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await frames();
      final session = tester.widget<InAppWebView>(find.byType(InAppWebView));
      expect(
        session.platform.params.initialSettings!.allowBackgroundAudioPlaying,
        defaultTargetPlatform == TargetPlatform.android,
      );
      final document = store.operation.id;
      final visits = portal.visited.length;
      final scripts = portal.scripts.length;

      void expectSession() {
        expect(
          find.byType(InAppWebView),
          findsOneWidget,
          reason: 'Playback must stay onstage under secondary pages.',
        );
        final current = tester.widget<InAppWebView>(
          find.byType(InAppWebView, skipOffstage: false),
        );
        expect(identical(current, session), isTrue);
        expect(platform.views, hasLength(1));
        expect(platform.mounts, 1);
        expect(platform.disposals, 0);
        expect(store.operation.id, document);
        expect(identical(store.playback.value, playback), isTrue);
        expect(portal.visited, hasLength(visits));
        expect(portal.reloads, 0);
        expect(
          portal.scripts.skip(scripts),
          isNot(anyElement(contains('dispose'))),
        );
        expect(
          portal.scripts.skip(scripts),
          isNot(anyElement(contains('media.load()'))),
        );
        expect(tester.takeException(), isNull);
      }

      expectSession();

      Future<void> closeRoute(Finder page) async {
        Navigator.pop(tester.element(page));
        await frames();
        expectSession();
      }

      await tester.tap(find.bySemanticsLabel(store.t('playbackSettings')));
      await frames();
      expectSession();
      await tester.tap(find.textContaining('${store.t('videoQuality')} ·'));
      await frames();
      expectSession();
      await closeRoute(find.byType(CupertinoActionSheet));
      await tester.tap(find.bySemanticsLabel(store.t('playbackSettings')));
      await frames();
      await tester.tap(find.text(store.t('playbackSpeed')));
      await frames();
      expectSession();
      await closeRoute(find.byType(CupertinoActionSheet));

      final synopsis = find.byKey(const ValueKey('open-full-synopsis'));
      await tester.ensureVisible(synopsis);
      await frames();
      await tester.tap(synopsis);
      await frames();
      expectSession();
      await closeRoute(find.byKey(const ValueKey('full-synopsis-page')));

      final playerContext = tester.element(find.byType(PlayerPage));
      const attachment = 'https://wall.bahamut.com.tw/session-test.png';
      addTearDown(
        () => PaintingBinding.instance.imageCache.evict(
          const NetworkImage(attachment),
        ),
      );
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawColor(Colors.blue, ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(16, 16);
        PaintingBinding.instance.imageCache.putIfAbsent(
          const NetworkImage(attachment),
          () => OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: image)),
          ),
        );
        picture.dispose();
      });
      portal.communityResponse = {
        ...commentPageJson(),
        'comments': [
          {...commentJson('1'), 'image': attachment},
        ],
      };
      openComments(playerContext, store, '20', 'Test Anime');
      await frames();
      expectSession();
      final attachedImage = find.byKey(
        const ValueKey('comment-attachment-$attachment'),
      );
      await tester.ensureVisible(attachedImage);
      await frames();
      await tester.tap(attachedImage);
      await frames();
      expectSession();
      await closeRoute(find.byKey(const ValueKey('comment-image-viewer')));
      await closeRoute(find.byKey(const ValueKey('comments-page')));

      showDanmakuPanel(playerContext, store);
      await frames();
      expectSession();
      await closeRoute(find.byKey(const ValueKey('danmaku-panel')));

      store.setPlayerFullscreen(true);
      await frames();
      expectSession();
      showDanmakuComposer(tester.element(find.byType(PlayerPage)), store);
      await frames();
      expectSession();
      await closeRoute(find.byKey(const ValueKey('danmaku-composer')));
      store.setPlayerFullscreen(false);
      await frames();
      expectSession();

      for (final fullscreen in [false, true]) {
        store.setPlayerFullscreen(fullscreen);
        await frames();
        // Control Center removes focus without hiding the application or
        // disabling its play/pause commands.
        final beforeInactive = portal.scripts.length;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await frames();
        expect(portal.scripts.length, beforeInactive);
        await store.controlPlayer('pause');
        expect(portal.scripts.last, contains('"pause"'));
        await store.controlPlayer('play');
        expect(portal.scripts.last, contains('"play"'));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await frames();
        expectSession();

        // App switching and screen lock both hide/pause the same session.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await frames();
        expectSession();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await frames();
        expect(portal.scripts.last, contains('media.pause()'));
        expect(portal.scripts.last, contains('__bahaPlayerBridge?.suspend()'));
        expectSession();
        // Returning from the lock screen can also change window insets.
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await frames();
        expect(portal.scripts.last, contains('__bahaMediaSuspended = false'));
        expect(portal.scripts.last, isNot(contains('.play(')));
        expectSession();
        tester.view.resetPadding();
        await frames();
        expectSession();
      }
      store.setPlayerFullscreen(false);
      await frames();

      await tester.pumpWidget(const SizedBox.shrink());
      expect(platform.disposals, 1);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
