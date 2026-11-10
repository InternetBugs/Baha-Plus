import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

void main() {
  Future<void> frames(WidgetTester tester) async {
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  WatchEntry record({
    String id = '10',
    String episode = '4',
    DateTime? watchedAt,
    String? nextVideoId,
  }) => WatchEntry.fromJson({
    'anime': {
      'id': id,
      'title': '測試動畫 $id',
      'cover': 'https://p2.bahamut.com.tw/$id.jpg',
      'latestVideoId': '99',
      'sections': <String>[],
    },
    'videoId': '20',
    'episodeLabel': episode,
    'progress': 1,
    'progressLabel': '觀看結束',
    if (watchedAt != null) 'watchedAt': watchedAt.toUtc().toIso8601String(),
    'nextVideoId': ?nextVideoId,
  });

  Future<AppStore> launch(
    WidgetTester tester,
    List<WatchEntry> entries, {
    double width = 400,
    String language = 'zh-Hant',
  }) async {
    tester.view.physicalSize = Size(width, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(
      () =>
          AppStore.create(storage: MemoryStorage(), animeSearch: FakeSearch()),
    ))!;
    addTearDown(store.dispose);
    store.history = entries;
    store.language = language;
    store.tab = 3;
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: BahaPlusApp(store: store, mountPortal: false),
      ),
    );
    await frames(tester);
    return store;
  }

  testWidgets(
    'history shows watch date and episode with conditional next action',
    (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 14, 42);
      final yesterday = DateTime(now.year, now.month, now.day - 1, 21, 30);
      final store = await launch(tester, [
        record(watchedAt: today, nextVideoId: '42'),
        record(id: '11', episode: '6', watchedAt: yesterday),
        record(
          id: '12',
          episode: '特別篇',
          watchedAt: DateTime(now.year - 1, 11, 6, 9, 5),
        ),
      ]);
      expect(find.text('今天 14:42 · 觀看至第 4 集'), findsOneWidget);
      expect(find.text('昨天 21:30 · 觀看至第 6 集'), findsOneWidget);
      expect(find.text('${now.year - 1}/11/06 09:05 · 觀看至特別篇'), findsOneWidget);
      expect(find.text(store.t('nextEpisode')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-next-10')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-next-11')), findsNothing);
      expect(find.byKey(const ValueKey('history-next-12')), findsNothing);
      expect(find.text(store.t('historyFinished')), findsNWidgets(3));
      expect(tester.takeException(), isNull);

      final portal = FakePortal();
      await store.attach(portal);
      final navigations = portal.visited.length;
      await tester.tap(find.byKey(const ValueKey('history-next-10')));
      await frames(tester);
      expect(portal.visited.length, navigations + 1);
      expect(portal.visited.last, OfficialSite.video('42'));
      expect(store.playingVideoId, '42');
      store.detach(portal);
    },
  );

  testWidgets('history without a timestamp keeps episode and resume action', (
    tester,
  ) async {
    final store = await launch(tester, [record()], language: 'zh-Hans');
    expect(find.text('观看至第 4 集'), findsOneWidget);
    expect(find.text(store.t('nextEpisode')), findsNothing);
    final portal = FakePortal();
    await store.attach(portal);
    await tester.tap(find.byKey(const ValueKey('history-play-10')));
    await frames(tester);
    expect(portal.visited.last, OfficialSite.video('20'));
    expect(tester.takeException(), isNull);
    store.detach(portal);
  });

  testWidgets('history controls fit a narrow screen and large text', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final store = await launch(tester, [
      record(watchedAt: DateTime(2025, 11, 6, 21, 30), nextVideoId: '42'),
    ], width: 320);
    expect(find.text(store.t('nextEpisode')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
