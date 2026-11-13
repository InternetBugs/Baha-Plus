import 'fake_playback.dart';
import 'fake_metadata.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

void main() {
  final spinner = find.byKey(const ValueKey('player-loading-indicator'));
  final speed = find.byKey(const ValueKey('player-loading-speed'));

  test(
    'playback state accepts optional download speed and rejects invalid values',
    () {
      final json = <String, dynamic>{
        'phase': 'loading',
        'surfaceReady': false,
        'paused': true,
        'buffering': true,
        'ended': false,
        'muted': false,
        'position': 0,
        'duration': 0,
        'buffered': 0,
        'rate': 1,
      };
      expect(PlaybackState.fromJson(json).downloadBytesPerSecond, 0);
      expect(
        PlaybackState.fromJson({
          ...json,
          'downloadBytesPerSecond': 1024,
        }).downloadBytesPerSecond,
        1024,
      );
      for (final invalid in [-1, double.nan, double.infinity, 1e13, '1000']) {
        expect(
          () => PlaybackState.fromJson({
            ...json,
            'downloadBytesPerSecond': invalid,
          }),
          throwsFormatException,
        );
      }
    },
  );

  for (final fullscreen in [false, true]) {
    testWidgets(
      'loading speed follows the spinner in ${fullscreen ? 'fullscreen' : 'portrait'}',
      (tester) async {
        tester.view.physicalSize = fullscreen
            ? const Size(850, 400)
            : const Size(400, 850);
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
        final portal = FakePortal();
        addTearDown(() {
          store.detach(portal);
          store.dispose();
        });
        await store.attach(portal);
        await playFixture(
          store,
          const Anime(
            id: '10',
            title: 'Test Anime',
            cover: '',
            latestVideoId: '20',
          ),
        );
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
        expect(spinner, findsOneWidget);
        expect(speed, findsOneWidget);
        expect(tester.widget<Text>(speed).data, '0 B/s');
        expect(
          tester.getTopLeft(speed).dy,
          greaterThan(tester.getBottomLeft(spinner).dy),
        );

        for (final entry in [
          (128.0, '128 B/s'),
          (512 * 1024.0, '512.0 KB/s'),
          (2.5 * 1024 * 1024, '2.5 MB/s'),
          (0.0, '0 B/s'),
        ]) {
          store.playback.value = PlaybackState(
            phase: PlaybackPhase.content,
            surfaceReady: true,
            paused: false,
            buffering: true,
            duration: 1200,
            downloadBytesPerSecond: entry.$1,
          );
          await tester.pump();
          expect(spinner, findsOneWidget);
          expect(tester.widget<Text>(speed).data, entry.$2);
        }

        for (final phase in [
          PlaybackPhase.content,
          PlaybackPhase.advertisement,
          PlaybackPhase.age,
          PlaybackPhase.verification,
          PlaybackPhase.official,
          PlaybackPhase.error,
        ]) {
          store.playback.value = PlaybackState(
            phase: phase,
            surfaceReady: true,
            buffering: phase != PlaybackPhase.content,
            duration: 1200,
            downloadBytesPerSecond: 1024 * 1024,
          );
          await tester.pump();
          expect(spinner, findsNothing);
          expect(speed, findsNothing);
        }

        await playFixture(
          store,
          const Anime(
            id: '10',
            title: 'Test Anime',
            cover: '',
            latestVideoId: '21',
          ),
        );
        await tester.pump();
        expect(tester.widget<Text>(speed).data, '0 B/s');
        store.browserError = true;
        store.playback.value = const PlaybackState(
          downloadBytesPerSecond: 1024,
        );
        await tester.pump();
        expect(spinner, findsNothing);
        expect(speed, findsNothing);
        expect(tester.takeException(), isNull);
        store.detach(portal);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
