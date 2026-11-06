import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/main.dart' as application;
import 'package:baha_plus/ui/app_root.dart';
import 'package:baha_plus/ui/comments_page.dart';
import 'package:baha_plus/ui/community_images.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'package:baha_plus/ui/synopsis_section.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real per-episode boards, decoded avatars, attachments and replies without publishing',
    (tester) async {
      Future<void> waitFor(bool Function() ready, {int seconds = 45}) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 150));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue);
      }

      Future<void> waitForImage(Finder parent) => waitFor(
        () => find
            .descendant(of: parent, matching: find.byType(RawImage))
            .evaluate()
            .any((element) => (element.widget as RawImage).image != null),
      );

      final output = Directory(
        '${Directory.systemTemp.path}/baha-community-acceptance',
      )..createSync(recursive: true);
      Future<void> screenshot(String name) async {
        await tester.pump(const Duration(milliseconds: 400));
        final bytes = await binding.takeScreenshot(name);
        await File('${output.path}/$name.png').writeAsBytes(bytes);
      }

      await application.main();
      await waitFor(() => find.byType(AppRoot).evaluate().isNotEmpty);
      final store = tester.widget<AppRoot>(find.byType(AppRoot)).store;
      final originalAppearance = store.appearance;
      addTearDown(() => store.setAppearance(originalAppearance));
      await waitFor(() => store.browserUri != null && !store.busy);
      // Inert GET-only metadata reads: never initialize a video or submit text.
      final target = await store.community('notification-target', {
        'videoId': '45916',
      });
      final anime = Anime.fromJson(target['anime'] as Json);
      await store.openDetail(anime);
      await waitFor(() => !store.detailLoading);
      expect(store.detailFailed, isFalse);
      final detail = store.detail!;
      expect(detail.rating, isNotNull);
      final page = await store.loadComments('45916');
      expect(page.comments, isNotEmpty);
      final illustrated = page.comments
          .take(10)
          .firstWhere(
            (comment) =>
                comment.avatar != null &&
                comment.image != null &&
                !comment.folded &&
                comment.replies > 0,
          );
      final replies = await store.loadReplies(illustrated.id);
      expect(replies, isNotEmpty);

      final context = tester.element(find.byType(AppRoot));
      Navigator.push<void>(
        context,
        CupertinoPageRoute(
          builder: (_) => DetailPage(store: store, anime: anime),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      final preview = find.byKey(const ValueKey('compact-comments-preview'));
      await waitFor(() => preview.evaluate().isNotEmpty);
      expect(
        tester.getTopLeft(find.byType(SynopsisSection)).dy,
        lessThan(tester.getTopLeft(preview).dy),
      );
      final summary = tester.widget<Text>(
        find.byKey(const ValueKey('synopsis-preview')),
      );
      expect(
        summary.data!.characters.length,
        lessThanOrEqualTo(SynopsisSection.previewLimit + 1),
      );
      await Scrollable.ensureVisible(tester.element(preview), alignment: .15);
      await tester.pump(const Duration(milliseconds: 500));
      final previewComment = find.byKey(
        ValueKey('preview-comment-${illustrated.id}'),
      );
      await waitFor(() => previewComment.evaluate().isNotEmpty);
      await waitForImage(
        find.descendant(
          of: previewComment,
          matching: find.byType(CommentAvatar),
        ),
      );
      await waitForImage(
        find.descendant(
          of: previewComment,
          matching: find.byType(CommentAttachment),
        ),
      );
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await screenshot('01-episode-board-preview');
      debugPrint(
        'Verified real decoded avatar and attachment in the inline board.',
      );

      final inline = find.byKey(const ValueKey('inline-comments-45916'));
      final openAll = find.byKey(const ValueKey('open-full-comments'));
      for (
        var step = 0;
        step < 30 && openAll.hitTestable().evaluate().isEmpty;
        step++
      ) {
        await tester.drag(inline, const Offset(0, -160));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(openAll.hitTestable(), findsOneWidget);
      for (final omitted in page.comments.skip(10)) {
        expect(
          find.byKey(ValueKey('preview-comment-${omitted.id}')),
          findsNothing,
        );
      }
      await screenshot('02-ten-comment-limit');
      await tester.tap(openAll);
      await waitFor(
        () => find
            .byKey(ValueKey('comment-${illustrated.id}'))
            .evaluate()
            .isNotEmpty,
      );
      final root = find.byKey(ValueKey('comment-${illustrated.id}'));
      await waitForImage(
        find.descendant(of: root, matching: find.byType(CommentAvatar)),
      );
      final attachment = find.descendant(
        of: root,
        matching: find.byType(CommentAttachment),
      );
      await Scrollable.ensureVisible(tester.element(attachment), alignment: .3);
      await waitForImage(attachment);
      await screenshot('03-board-with-real-images');
      await tester.tap(
        find
            .descendant(of: attachment, matching: find.byType(GestureDetector))
            .first,
      );
      await waitFor(
        () => find
            .byKey(const ValueKey('comment-image-viewer'))
            .evaluate()
            .isNotEmpty,
      );
      await waitForImage(find.byType(InteractiveViewer));
      await screenshot('04-attachment-viewer');
      Navigator.pop(
        tester.element(find.byKey(const ValueKey('comment-image-viewer'))),
      );
      await tester.pump(const Duration(milliseconds: 600));

      final repliesButton = find.descendant(
        of: root,
        matching: find.byIcon(CupertinoIcons.chat_bubble),
      );
      await Scrollable.ensureVisible(
        tester.element(repliesButton),
        alignment: .5,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(repliesButton);
      await waitFor(
        () => find
            .byKey(ValueKey('comment-${replies.first.id}'))
            .evaluate()
            .isNotEmpty,
      );
      final reply = find.byKey(ValueKey('comment-${replies.first.id}'));
      await Scrollable.ensureVisible(tester.element(reply), alignment: .35);
      if (replies.first.avatar != null) {
        await waitForImage(
          find.descendant(of: reply, matching: find.byType(CommentAvatar)),
        );
      }
      await screenshot('05-official-replies');
      // Exercise the reply editor locally. Deliberately never tap its send button.
      await tester.tap(
        find.descendant(
          of: reply,
          matching: find.byIcon(CupertinoIcons.arrowshape_turn_up_left),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(store.t('replyPlaceholder')), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();

      final board = find.byKey(const ValueKey('comments-page'));
      final list = find.byKey(const ValueKey('comment-list'));
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first,
      );
      scroll.position.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 400));
      await store.setAppearance('dark');
      await waitFor(
        () => Theme.of(tester.element(board)).brightness == Brightness.dark,
      );
      await screenshot('07-dark-board');
      await store.setAppearance(originalAppearance);
      await tester.pump(const Duration(milliseconds: 500));
      final other = detail.episodes.firstWhere(
        (episode) => episode.id != '45916',
      );
      await tester.tap(find.byKey(const ValueKey('board-episode-selector')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(ValueKey('board-select-${other.id}')));
      await tester.pump(const Duration(milliseconds: 500));
      final otherPage = await store.loadComments(other.id);
      if (otherPage.comments.isNotEmpty) {
        await waitFor(
          () => find
              .byKey(ValueKey('comment-${otherPage.comments.first.id}'))
              .evaluate()
              .isNotEmpty,
        );
      }
      expect(find.byKey(ValueKey('comment-${illustrated.id}')), findsNothing);
      expect(find.text(store.t('commentPlaceholder')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CommentsPage &&
              widget.episodes.any((episode) => episode.id == other.id),
        ),
        findsOneWidget,
      );
      await screenshot('06-another-episode-board');
      await File('${output.path}/result.json').writeAsString(
        jsonEncode({
          'videoId': '45916',
          'otherVideoId': other.id,
          'commentCount': page.total,
          'avatarDecoded': true,
          'attachmentDecoded': true,
          'replyAvatarDecoded': replies.first.avatar != null,
          'darkAppearance': true,
          'inlineLimit': 10,
          'replyCount': replies.length,
          'episodeIsolation': page.messageId != otherPage.messageId,
          'publishedContent': false,
        }),
      );
      expect(page.messageId, isNot(otherPage.messageId));
      expect(board, findsOneWidget);
      expect(tester.takeException(), isNull);
      debugPrint(
        'Verified distinct episode boards and real replies; no publishing actions executed.',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
