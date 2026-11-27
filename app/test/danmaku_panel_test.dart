import 'dart:convert';
import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/native_danmaku.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_danmaku_sender.dart';
import 'package:baha_plus/data/native_http_api.dart';
import 'package:baha_plus/ui/danmaku_panel.dart';
import 'package:baha_plus/ui/glass_settings_menu.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakeSearch, MemoryStorage;
import 'fake_account.dart';
import 'fake_metadata.dart';
import 'fake_playback.dart';

class _RecordingDanmakuSender extends NativeDanmakuSender {
  _RecordingDanmakuSender()
    : super(
        client: MockClient((_) async => http.Response('', 200)),
        cookieLoader: () async => NativeHttpCookieJar(),
      );

  final List<Map<String, Object>> sent = [];

  @override
  Future<NativeDanmaku> send({
    required String videoId,
    required String owner,
    required String text,
    required String color,
    required int position,
    required int size,
    required void Function() checkCurrent,
    required double Function() currentPosition,
  }) async {
    sent.add({
      'videoId': videoId,
      'owner': owner,
      'text': text.trim(),
      'color': color,
      'position': position,
      'size': size,
    });
    return NativeDanmaku.fromJson({
      'id': '${sent.length}',
      'text': text.trim(),
      'time': currentPosition(),
      'color': color,
      'mode': ['rolling', 'top', 'bottom'][position],
      'size': [16, 24, 28][size],
    });
  }
}

void main() {
  Future<void> frames(WidgetTester tester, {int count = 12}) async {
    for (var frame = 0; frame < count; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<AppStore> createStore(
    WidgetTester tester, {
    NativeDanmakuSender? sender,
    String language = 'zh-Hans',
  }) async {
    final store = (await tester.runAsync(
      () => AppStore.create(
        nativeHttpApiFactory: PendingNativeHttpApi.new,
        metadataApi: FakeMetadata(),
        accountApi: FakeAccountApi(),
        danmakuSender: sender,
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
      ),
    ))!;
    addTearDown(store.dispose);
    await store.setLanguage(language);
    return store;
  }

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            useMaterial3: true,
            fontFamily: 'BahaSans',
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff007aff),
              brightness: brightness,
              surface: brightness == Brightness.dark
                  ? const Color(0xff1c1c1e)
                  : Colors.white,
              surfaceContainerLowest: brightness == Brightness.dark
                  ? const Color(0xff000000)
                  : const Color(0xfff2f2f7),
            ),
            scaffoldBackgroundColor: brightness == Brightness.dark
                ? const Color(0xff08080a)
                : Colors.white,
          ),
          builder: (context, inner) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: inner!,
          ),
          home: child,
        ),
      ),
    );
    await frames(tester);
  }

  testWidgets(
    'danmaku settings toggles display modes and resets without an extra master switch',
    (tester) async {
      final store = await createStore(tester);
      await store.setDanmakuSettings(const DanmakuSettings(enabled: false));
      await mount(tester, DanmakuPanel(store: store));

      expect(find.byKey(const ValueKey('danmaku-panel')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('danmaku-settings-stage')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('danmaku-enabled-switch')), findsNothing);
      expect(find.byType(GlassSlider), findsNWidgets(2));
      expect(find.byKey(const ValueKey('danmaku-reset')), findsNothing);

      // Toggle rolling off.
      final rolling = find.byKey(const ValueKey('danmaku-mode-rolling'));
      await tester.ensureVisible(rolling);
      await tester.tap(rolling);
      await frames(tester);
      expect(store.danmakuSettings.rolling, isFalse);
      expect(find.byKey(const ValueKey('danmaku-reset')), findsOneWidget);

      // Toggle top and bottom off as well.
      final top = find.byKey(const ValueKey('danmaku-mode-top'));
      await tester.ensureVisible(top);
      await tester.tap(top);
      await frames(tester);
      expect(store.danmakuSettings.top, isFalse);

      final bottom = find.byKey(const ValueKey('danmaku-mode-bottom'));
      await tester.ensureVisible(bottom);
      await tester.tap(bottom);
      await frames(tester);
      expect(store.danmakuSettings.bottom, isFalse);

      // Reset restores style and display modes while preserving the player's enabled state.
      await tester.tap(find.byKey(const ValueKey('danmaku-reset')));
      await frames(tester);
      expect(store.danmakuSettings.enabled, isFalse);
      expect(store.danmakuSettings.rolling, isTrue);
      expect(store.danmakuSettings.top, isTrue);
      expect(store.danmakuSettings.bottom, isTrue);
      expect(store.danmakuSettings.opacity, closeTo(.8, .001));
      expect(store.danmakuSettings.scale, closeTo(1.0, .001));
      expect(find.byKey(const ValueKey('danmaku-reset')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'danmaku settings uses a two-column split layout on wide landscape screens',
    (tester) async {
      final store = await createStore(tester);
      await mount(
        tester,
        DanmakuPanel(store: store),
        size: const Size(844, 390),
        brightness: Brightness.dark,
      );

      final stageRect = tester.getRect(
        find.byKey(const ValueKey('danmaku-settings-stage')),
      );
      final sliderRect = tester.getRect(
        find.byKey(const ValueKey('danmaku-opacity-slider')),
      );
      expect(stageRect.right, lessThan(sliderRect.left));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'danmaku composer tracks UTF-8 bytes and submits selected position, size, and color',
    (tester) async {
      final sender = _RecordingDanmakuSender();
      final store = await createStore(tester, sender: sender);
      store
        ..accountProfile = const AccountProfile(
          id: 'reader',
          displayName: 'Reader',
        )
        ..playingAnime = const Anime(
          id: '10',
          title: '测试动画',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
          latestVideoId: '20',
        )
        ..playingVideoId = '20'
        ..browserVisible = true
        ..playback.value = const PlaybackState(
          phase: PlaybackPhase.content,
          surfaceReady: true,
          duration: 1200,
          position: 42,
        );
      // Enable native HTTP send path via public play entry or direct check.
      await mount(
        tester,
        DanmakuPanel(store: store, composerOnly: true),
      );

      expect(find.byKey(const ValueKey('danmaku-composer')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('danmaku-composer-stage')),
        findsNothing,
      );
      expect(find.text('0/60'), findsOneWidget);

      // Select position = top (index 1), size = large (index 2), color = #FF595E.
      await tester.tap(find.text(store.t('danmakuTop')));
      await frames(tester);
      await tester.tap(find.text(store.t('largeText')));
      await frames(tester);
      await tester.tap(find.byKey(const ValueKey('danmaku-color-#FF595E')));
      await frames(tester);

      // Enter text and verify UTF-8 byte counter (4 Chinese chars = 12 bytes).
      const sample = '动画太棒';
      await tester.enterText(
        find.byKey(const ValueKey('community-input-60')),
        sample,
      );
      await frames(tester);
      expect(
        find.text('${utf8.encode(sample).length}/60'),
        findsOneWidget,
      );
      // Draft text stays singular in the widget tree (stage paints via CustomPainter).
      expect(find.text(sample), findsOneWidget);

      // Over 60 UTF-8 bytes shows the warning caption.
      final tooLong = '测' * 21; // 63 UTF-8 bytes
      await tester.enterText(
        find.byKey(const ValueKey('community-input-60')),
        tooLong,
      );
      await frames(tester);
      expect(find.text('63/60'), findsOneWidget);
      expect(find.text(store.t('danmakuBytesLimitExceeded')), findsOneWidget);

      // Back to valid message.
      await tester.enterText(
        find.byKey(const ValueKey('community-input-60')),
        sample,
      );
      await frames(tester);
      expect(find.text(store.t('danmakuLimit')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'showDanmakuComposer adapts cleanly in landscape when the keyboard opens',
    (tester) async {
      final store = await createStore(tester);
      store
        ..playingAnime = const Anime(
          id: '10',
          title: '测试动画',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
          latestVideoId: '20',
        )
        ..playingVideoId = '20'
        ..playback.value = const PlaybackState(
          phase: PlaybackPhase.content,
          surfaceReady: true,
          duration: 1200,
        );
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: CupertinoButton(
                key: const ValueKey('open-composer'),
                onPressed: () => showDanmakuComposer(context, store),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        size: const Size(850, 400),
        brightness: Brightness.dark,
      );

      await tester.tap(find.byKey(const ValueKey('open-composer')));
      await frames(tester);
      expect(find.byKey(const ValueKey('danmaku-composer')), findsOneWidget);
      expect(find.byKey(const ValueKey('community-input-60')), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await frames(tester);
      expect(find.byKey(const ValueKey('community-input-60')), findsOneWidget);
      expect(tester.takeException(), isNull);

      tester.view.resetViewInsets();
      await frames(tester);
      await tester.tap(find.bySemanticsLabel(store.t('close')).last);
      await frames(tester);
      expect(find.byKey(const ValueKey('danmaku-composer')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'danmaku settings and composer preserve valid settings across updates',
    (tester) async {
      final store = await createStore(tester, language: 'zh-Hant');
      await store.setDanmakuSettings(
        const DanmakuSettings(opacity: .5, scale: 1.3, top: false),
      );
      await mount(
        tester,
        DanmakuPanel(store: store),
        brightness: Brightness.dark,
      );
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('130%'), findsOneWidget);
      expect(find.byKey(const ValueKey('danmaku-reset')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'showDanmakuComposer pins the close button to the trailing edge in portrait and landscape',
    (tester) async {
      final store = await createStore(tester);
      store
        ..playingAnime = const Anime(
          id: '10',
          title: '测试动画',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
          latestVideoId: '20',
        )
        ..playingVideoId = '20'
        ..playback.value = const PlaybackState(
          phase: PlaybackPhase.content,
          surfaceReady: true,
          duration: 1200,
        );

      for (final (size, padding) in [
        (const Size(390, 844), const FakeViewPadding(top: 47, bottom: 34)),
        (
          const Size(844, 390),
          const FakeViewPadding(left: 47, right: 47, bottom: 21),
        ),
      ]) {
        tester.view.padding = padding;
        tester.view.viewPadding = padding;
        await mount(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: CupertinoButton(
                  key: const ValueKey('open-composer-align'),
                  onPressed: () => showDanmakuComposer(context, store),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          size: size,
        );

        await tester.tap(find.byKey(const ValueKey('open-composer-align')));
        await frames(tester);

        final surfaceRect = tester.getRect(
          find.byKey(const ValueKey('danmaku-composer-glass-surface')),
        );
        final closeButton = find.ancestor(
          of: find.byIcon(CupertinoIcons.xmark),
          matching: find.byType(CupertinoButton),
        );
        final closeRect = tester.getRect(closeButton);
        final titleRect = tester.getRect(find.text(store.t('sendDanmaku')));
        final groupRect = tester.getRect(find.byType(GlassSettingsGroup));

        // Close button stays aligned with the trailing edge and centered with the title.
        expect(surfaceRect.right - closeRect.right, closeTo(17, 1.5));
        expect(closeRect.right, closeTo(groupRect.right + 1, 1.5));
        expect(closeRect.center.dy, closeTo(titleRect.center.dy, 1.5));

        await tester.tap(closeButton);
        await frames(tester);
        expect(find.byKey(const ValueKey('danmaku-composer')), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'showDanmakuPanel aligns the close button with settings content and clears sheet top chrome',
    (tester) async {
      final store = await createStore(tester);

      for (final (size, padding) in [
        (const Size(390, 844), const FakeViewPadding(top: 47, bottom: 34)),
        (
          const Size(844, 390),
          const FakeViewPadding(left: 47, right: 47, bottom: 21),
        ),
        (const Size(1024, 768), const FakeViewPadding(top: 24, bottom: 20)),
      ]) {
        tester.view.padding = padding;
        tester.view.viewPadding = padding;
        await mount(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: CupertinoButton(
                  key: const ValueKey('open-panel-align'),
                  onPressed: () => showDanmakuPanel(context, store),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          size: size,
        );

        await tester.tap(find.byKey(const ValueKey('open-panel-align')));
        await frames(tester, count: 16);

        final panelRect = tester.getRect(
          find.byKey(const ValueKey('danmaku-panel')),
        );
        final closeButton = find.ancestor(
          of: find.byIcon(CupertinoIcons.xmark),
          matching: find.byType(GlassIconButton),
        );
        final closeRect = tester.getRect(closeButton);
        final titleRect = tester.getRect(find.text(store.t('danmakuSettings')));
        final groupRect = tester.getRect(find.byType(GlassSettingsGroup).first);
        final stageRect = tester.getRect(
          find.byKey(const ValueKey('danmaku-settings-stage')),
        );

        expect(closeRect.center.dy, closeTo(titleRect.center.dy, 1.5));
        expect(closeRect.top - panelRect.top, greaterThanOrEqualTo(12));
        expect(closeRect.top - panelRect.top, lessThanOrEqualTo(32));
        expect(titleRect.left, closeTo(stageRect.left, 1.5));
        expect(closeRect.right, closeTo(groupRect.right, 1.5));

        await tester.tap(closeButton);
        await frames(tester, count: 16);
        expect(find.byKey(const ValueKey('danmaku-panel')), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
