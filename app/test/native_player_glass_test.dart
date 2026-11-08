import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

void main() {
  for (final native in [false, true]) {
    testWidgets(
      'video glass follows the actual playback backend: native=$native',
      (tester) async {
        tester.view.physicalSize = const Size(400, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final store = (await tester.runAsync(
          () => AppStore.create(
            storage: MemoryStorage(),
            animeSearch: FakeSearch(),
          ),
        ))!;
        addTearDown(store.dispose);
        final portal = FakePortal()
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
        store.playback.value = const PlaybackState(
          phase: PlaybackPhase.content,
          surfaceReady: true,
          paused: true,
          buffering: false,
          position: 30,
          duration: 1200,
          hasDanmaku: true,
        );
        if (native) store.nativePlaybackDocument = store.operation.id;
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
        await tester.pump(const Duration(milliseconds: 300));
        final toggle = tester.widget<GlassIconButton>(
          find.byKey(const ValueKey('player-danmaku-button')),
        );
        expect(toggle.platformViewBackdrop, !native);
        if (native) expect(toggle.quality, GlassQuality.standard);
        store.setPlayerFullscreen(true);
        await tester.pump(const Duration(milliseconds: 300));
        final controls = tester.widget<GlassContainer>(
          find.byKey(const ValueKey('video-glass-controls')),
        );
        expect(controls.platformViewBackdrop, !native);
        if (native) expect(controls.quality, GlassQuality.standard);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
