import 'fake_metadata.dart';
import 'dart:ui' as ui;

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/ui/buffered_playback_track.dart';
import 'package:baha_plus/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

const _gray = Color(0xff8e8e93);

Json _json() => {
  'phase': 'content',
  'surfaceReady': true,
  'paused': true,
  'buffering': false,
  'ended': false,
  'muted': false,
  'position': 10,
  'duration': 100,
  'buffered': 80,
  'rate': 1,
};

void main() {
  test(
    'buffer intervals preserve gaps, legacy endpoints and empty buffers',
    () {
      final legacy = PlaybackState.fromJson(_json());
      expect(legacy.bufferRanges, [(start: 0.0, end: 80.0)]);
      final state = PlaybackState.fromJson({
        ..._json(),
        'bufferedRanges': [
          [0, 30],
          [60, 80],
        ],
      });
      expect(state.bufferRanges, [
        (start: 0.0, end: 30.0),
        (start: 60.0, end: 80.0),
      ]);
      expect(
        PlaybackState.fromJson({..._json(), 'bufferedRanges': []}).bufferRanges,
        isEmpty,
      );
      expect(const PlaybackState().bufferRanges, isEmpty);
      expect(
        () => state.bufferRanges.add((start: 90, end: 100)),
        throwsUnsupportedError,
      );
    },
  );

  test('invalid buffered interval payloads are rejected at the bridge', () {
    for (final ranges in <dynamic>[
      '0-80',
      [30],
      [
        [0],
      ],
      [
        ['0', 30],
      ],
      [
        [-1, 30],
      ],
      [
        [60, 30],
      ],
      [
        [0, double.nan],
      ],
      [
        [0, double.infinity],
      ],
      [
        [90, 110],
      ],
      List.filled(513, [0, 1]),
    ]) {
      expect(
        () => PlaybackState.fromJson({..._json(), 'bufferedRanges': ranges}),
        throwsFormatException,
        reason: '$ranges',
      );
    }
  });

  const capture = ValueKey('buffer-track-capture');

  Future<void> draw(
    WidgetTester tester,
    PlaybackState state, {
    Color color = Colors.white,
    TextDirection direction = TextDirection.ltr,
    double? previewPosition,
  }) async {
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: Directionality(
          textDirection: direction,
          child: Center(
            child: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: color == Colors.white ? Colors.black : Colors.white,
                child: SizedBox(
                  width: 400,
                  height: 32,
                  child: BufferedPlaybackTrack(
                    state: state,
                    color: color,
                    child: GlassSlider(
                      value: previewPosition ?? state.position,
                      max: state.duration > 0 ? state.duration : 1,
                      thumbRadius: 8,
                      trackHeight: 4,
                      activeColor: color,
                      inactiveColor: Colors.transparent,
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<List<Color>> pixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final colors = List.generate(image.width, (x) {
      final offset = (16 * image.width + x) * 4;
      return Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    });
    image.dispose();
    return colors;
  }

  for (final color in [Colors.white, const Color(0xff1c1c1e)]) {
    testWidgets(
      'played, buffered and uncached tracks remain distinct: $color',
      (tester) async {
        await draw(
          tester,
          const PlaybackState(
            position: 10,
            duration: 100,
            buffered: 80,
            bufferedRanges: [(start: 0, end: 30), (start: 60, end: 80)],
          ),
          color: color,
        );
        final row = await pixels(tester);
        expect(row[10], color, reason: 'Played track covers the gray buffer.');
        expect(row[80], _gray);
        expect(row[200], isNot(_gray), reason: 'Seek gaps remain uncached.');
        expect(row[280], _gray);
        expect(row[360], row[200]);

        await draw(
          tester,
          const PlaybackState(
            position: 10,
            duration: 100,
            buffered: 80,
            bufferedRanges: [(start: 0, end: 30), (start: 60, end: 80)],
          ),
          color: color,
          previewPosition: 50,
        );
        final preview = await pixels(tester);
        expect(
          preview[160],
          color,
          reason: 'Seek previews cover the buffer track.',
        );
        expect(
          preview[280],
          _gray,
          reason: 'Previewing does not extend the cache.',
        );
        expect(preview[360], row[360]);

        await draw(
          tester,
          const PlaybackState(
            position: 10,
            duration: 100,
            buffered: 95,
            bufferedRanges: [(start: 0, end: 95)],
          ),
          color: color,
        );
        expect((await pixels(tester))[360], _gray);

        await draw(tester, const PlaybackState(), color: color);
        final cleared = await pixels(tester);
        expect(cleared[280], isNot(_gray));
        expect(cleared[360], isNot(_gray));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('buffer track mirrors the slider in RTL', (tester) async {
    await draw(
      tester,
      const PlaybackState(
        position: 10,
        duration: 100,
        bufferedRanges: [(start: 0, end: 30)],
      ),
      direction: TextDirection.rtl,
    );
    final row = await pixels(tester);
    expect(row[390], Colors.white);
    expect(row[320], _gray);
    expect(row[80], isNot(_gray));
  });

  testWidgets(
    'buffer updates in normal and fullscreen controls and resets on episode change',
    (tester) async {
      tester.view.physicalSize = const Size(850, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = (await tester.runAsync(
        () => AppStore.create(
          metadataApi: FakeMetadata(),
          storage: MemoryStorage(),
          animeSearch: FakeSearch(),
        ),
      ))!;
      addTearDown(store.dispose);
      await store.attach(FakePortal());
      const anime = Anime(
        id: '10',
        title: 'Test',
        latestVideoId: '20',
        cover: '',
      );
      await store.play(anime);
      store.playback.value = PlaybackState.fromJson(_json());
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
      final track = find.byKey(const ValueKey('player-buffered-track'));
      expect(tester.widget<BufferedPlaybackTrack>(track).state.buffered, 80);
      store.playback.value = PlaybackState.fromJson({
        ..._json(),
        'buffered': 95,
        'bufferedRanges': [
          [0, 95],
        ],
      });
      await tester.pump();
      expect(tester.widget<BufferedPlaybackTrack>(track).state.bufferRanges, [
        (start: 0.0, end: 95.0),
      ]);
      store.setPlayerFullscreen(true);
      await tester.pump();
      expect(track, findsOneWidget);
      expect(tester.widget<BufferedPlaybackTrack>(track).state.buffered, 95);
      await store.play(
        anime,
        episode: const Episode(id: '21', label: '2'),
      );
      await tester.pump();
      expect(store.playback.value.bufferRanges, isEmpty);
      expect(track, findsNothing, reason: 'Loading hides normal controls.');
      store.playback.value = PlaybackState.fromJson({
        ..._json(),
        'buffered': 0,
        'bufferedRanges': [],
      });
      await tester.pump();
      expect(
        tester.widget<BufferedPlaybackTrack>(track).state.bufferRanges,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await store.setApplicationActive(false);
      expect(tester.takeException(), isNull);
    },
  );
}
