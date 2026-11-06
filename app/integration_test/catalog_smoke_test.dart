import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:baha_plus/main.dart' as application;
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/seasonal_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real public search, main visuals, carousel and seasonal timeline',
    (tester) async {
      Future<void> waitFor(bool Function() ready, {int seconds = 40}) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 150));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 100));
        expect(ready(), isTrue);
      }

      Future<void> waitForArtwork(Finder parent) async {
        await waitFor(
          () => find
              .descendant(of: parent, matching: find.byType(RawImage))
              .evaluate()
              .any((element) => (element.widget as RawImage).image != null),
        );
      }

      await application.main();
      await waitFor(() => find.byType(AppRoot).evaluate().isNotEmpty);
      final store = tester.widget<AppRoot>(find.byType(AppRoot)).store;
      await tester.tap(
        find
            .descendant(
              of: find.byType(GlassTabBar),
              matching: find.text(store.t('search')),
            )
            .hitTestable()
            .first,
      );
      await tester.pump(const Duration(milliseconds: 500));
      for (final query in ['進擊', '进击']) {
        await tester.enterText(find.byType(EditableText), query);
        await waitFor(
          () =>
              !store.searching &&
              (store.searchedQuery == query || store.searchFailed),
        );
        if (store.searchFailed) {
          try {
            await store.searchService.search(query);
          } catch (error) {
            fail(
              'Public search transport failed: ${error.runtimeType}: $error',
            );
          }
        }
        expect(store.searchFailed, isFalse);
        expect(store.searchResults, isNotEmpty);
        expect(store.tab, 4);
        expect(find.text(store.searchResults.first.title), findsOneWidget);
        expect(find.text(store.t('officialSearch')), findsNothing);
      }
      debugPrint('Verified real API search in both Chinese scripts.');
      await tester.enterText(find.byType(EditableText), '');
      FocusManager.instance.primaryFocus?.unfocus();
      await waitFor(() => store.seasonal.isNotEmpty);
      await waitFor(() => store.seasonal.first.poster != null, seconds: 60);
      final first = store.seasonal.first;
      expect(first.poster, isNot(first.cover));

      store.selectTab(2, filter: 'season');
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byKey(const ValueKey('library-waterfall')), findsOneWidget);
      final libraryTile = tester.widget<AnimeTile>(
        find.byKey(ValueKey('library-${first.id}')),
      );
      expect(libraryTile.poster, isTrue);
      expect(
        tester
            .widget<Artwork>(
              find.descendant(
                of: find.byKey(ValueKey('library-${first.id}')),
                matching: find.byType(Artwork),
              ),
            )
            .url,
        first.poster,
      );
      await waitForArtwork(find.byKey(ValueKey('library-${first.id}')));
      debugPrint('Verified decoded main visual and library waterfall.');

      store.selectTab(0);
      await tester.pump(const Duration(milliseconds: 700));
      final carousel = find.byKey(const ValueKey('home-featured-carousel'));
      expect(carousel, findsOneWidget);
      await waitForArtwork(carousel);
      final pages = tester.widget<PageView>(
        find.descendant(of: carousel, matching: find.byType(PageView)),
      );
      await tester.drag(carousel, const Offset(-280, 0));
      await tester.pump(const Duration(milliseconds: 800));
      expect(pages.controller!.page, greaterThan(.5));
      debugPrint('Verified horizontal featured carousel.');

      final heading = find.descendant(
        of: find.byType(SectionHeading),
        matching: find.text(store.t('seasonal')),
      );
      await Scrollable.ensureVisible(
        tester.element(heading),
        alignment: .35,
        duration: Duration.zero,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: heading, matching: find.byType(SectionHeading)),
          matching: find.byType(CupertinoButton),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(SeasonalPage), findsOneWidget);
      final episodeTile = tester.widget<AnimeTile>(
        find.byType(AnimeTile).first,
      );
      expect(episodeTile.poster, isFalse);
      expect(episodeTile.showUpdateTime, isTrue);
      expect(store.tab, 0);
      await waitForArtwork(find.byType(AnimeTile).first);
      debugPrint('Verified decoded episode image and seasonal timeline.');
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
