import 'dart:convert';

import 'package:baha_plus/main.dart' as application;
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:baha_plus/ui/official_browser.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live native catalog, artwork/search and video detail mount no WebView',
    (tester) async {
      Future<void> waitFor(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue);
      }

      void expectNoWebView() {
        expect(find.byType(OfficialBrowser, skipOffstage: false), findsNothing);
        expect(find.byType(InAppWebView, skipOffstage: false), findsNothing);
      }

      await application.main();
      await waitFor(() => find.byType(AppRoot).evaluate().isNotEmpty);
      final store = tester.widget<AppRoot>(find.byType(AppRoot)).store;
      await waitFor(
        () =>
            !store.catalogLoading &&
            (store.catalog.items.isNotEmpty || store.catalogFailed),
      );
      expect(store.catalogFailed, isFalse);
      expect(store.seasonal, isNotEmpty);
      expectNoWebView();

      // A real startup can display release notes over the catalog.
      await waitFor(() => !store.updates.checking);
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byType(CupertinoAlertDialog).evaluate().isNotEmpty) {
        await tester.tap(find.text(store.t('updateLater')));
        await tester.pump(const Duration(milliseconds: 500));
      }

      // The public search transport also supplies the missing main visuals.
      final results = await tester.runAsync(
        () => store.searchService.search('進擊'),
      );
      expect(results, isNotEmpty);
      expectNoWebView();

      final sample = store.seasonal.first;
      store.selectTab(2, filter: 'season');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(find.byKey(ValueKey('library-${sample.id}')));
      await tester.pump(const Duration(milliseconds: 700));
      await waitFor(() => !store.detailLoading);
      expect(find.byType(DetailPage), findsOneWidget);
      expect(store.detailFailed, isFalse);
      expect(
        store.detail!.episodes.any(
          (episode) => episode.id == sample.latestVideoId,
        ),
        isTrue,
      );
      expect(store.needsOfficialPortal, isFalse);
      expectNoWebView();
      expect(tester.takeException(), isNull);

      final report = <String, Object?>{
        'catalogItems': store.catalog.items.length,
        'searchResults': results!.length,
        'publicAnimeId': sample.id,
        'publicVideoId': sample.latestVideoId,
        'detailEpisodes': store.detail!.episodes.length,
        'officialBrowserWidgetsIncludingOffstage': 0,
        'inAppWebViewWidgetsIncludingOffstage': 0,
        'playbackStarted': false,
        'accountUsed': false,
      };
      binding.reportData = report;
      debugPrint('BAHA_NATIVE_METADATA ${jsonEncode(report)}');
      // Optional window for a host-side dumpsys meminfo sample of this app.
      if (const bool.fromEnvironment('BAHA_METADATA_INSPECTION')) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 20)),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
