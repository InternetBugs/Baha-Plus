import 'fake_metadata.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/ui/comments_page.dart';
import 'package:baha_plus/ui/comments_preview.dart';
import 'package:baha_plus/ui/community_images.dart';
import 'package:baha_plus/ui/danmaku_panel.dart';
import 'package:baha_plus/ui/notifications_page.dart';
import 'package:baha_plus/ui/synopsis_section.dart';
import 'package:baha_plus/ui/detail_page.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;
import 'community_test.dart'
    show commentPageJson, commentJson, notificationJson;

void main() {
  Future<void> frames(WidgetTester tester) async {
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(AppStore, FakePortal)> setup(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
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
    final portal = FakePortal();
    await store.attach(portal);
    store
        .navigationFailed(); // The fake portal has no catalog navigation to finish.
    return (store, portal);
  }

  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            useMaterial3: true,
            fontFamily: 'BahaSans',
            scaffoldBackgroundColor: brightness == Brightness.dark
                ? const Color(0xff111113)
                : const Color(0xfff2f2f7),
          ),
          builder: (context, child) => DefaultTextStyle(
            style: TextStyle(
              fontFamily: 'BahaSans',
              fontFamilyFallback: const ['BahaSansSC'],
              fontSize: 16,
              color: Theme.of(context).colorScheme.onSurface,
              decoration: TextDecoration.none,
            ),
            child: CupertinoTheme(
              data: CupertinoThemeData(
                brightness: brightness,
                textTheme: const CupertinoTextThemeData(
                  textStyle: TextStyle(fontFamily: 'BahaSans'),
                ),
              ),
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
          ),
          home: RepaintBoundary(
            key: const ValueKey('community-preview'),
            child: page,
          ),
        ),
      ),
    );
    await frames(tester);
  }

  testWidgets(
    'message board loads official rows, changes sort and deduplicates paginated results',
    (tester) async {
      final (store, portal) = await setup(tester);
      portal.communityHandler = (action, args) async => commentPageJson(
        id: args['page'] == 0 ? '1' : '2',
        nextPage: args['page'] == 0 ? 2 : 0,
      );
      await mount(
        tester,
        CommentsPage(store: store, videoId: '20', title: '測試動畫 · 第 6 集'),
      );
      expect(find.byKey(const ValueKey('comment-1')), findsOneWidget);
      expect(find.text('建議排序'), findsOneWidget);
      expect(find.byType(GlassContainer), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('comments-more')));
      await frames(tester);
      expect(find.byKey(const ValueKey('comment-2')), findsOneWidget);
      expect(portal.communityRequests.last['page'], 2);
      await tester.tap(find.byKey(const ValueKey('comment-order-0')));
      await frames(tester);
      expect(portal.communityRequests.last['order'], 0);
      expect(find.byKey(const ValueKey('comment-2')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a synopsis stops at 200 characters and opens the unabridged text on a second page',
    (tester) async {
      final (store, _) = await setup(tester);
      final description = '${'🧑‍🚀故事' * 70}最後的完整內容';
      await mount(
        tester,
        SingleChildScrollView(
          child: SynopsisSection(
            store: store,
            title: '測試動畫',
            description: description,
          ),
        ),
      );
      final preview = tester.widget<Text>(
        find.byKey(const ValueKey('synopsis-preview')),
      );
      expect(preview.data!.characters.length, SynopsisSection.previewLimit + 1);
      expect(preview.data!.endsWith('…'), isTrue);
      expect(find.text(description), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('open-full-synopsis')),
      );
      await tester.tap(find.byKey(const ValueKey('open-full-synopsis')));
      await frames(tester);
      expect(find.byKey(const ValueKey('full-synopsis-page')), findsOneWidget);
      expect(find.text(description), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail shows the series rating without loading an episode board',
    (tester) async {
      final (store, portal) = await setup(tester);
      portal.communityResponse = commentPageJson();
      store.detail = AnimeDetail.fromJson({
        'title': '測試動畫',
        'description': '完整的短篇故事介紹',
        'episodes': [
          {'id': '20', 'label': '1'},
        ],
        'metadata': [],
        'rating': {
          'value': 4.7,
          'count': 10,
          'distribution': [0, 0, 0, 3, 7],
        },
      });
      await mount(
        tester,
        DetailPage(
          store: store,
          anime: const Anime(
            id: '10',
            title: '測試動畫',
            cover: 'https://p2.bahamut.com.tw/10.jpg',
            latestVideoId: '20',
          ),
        ),
      );
      expect(find.byKey(const ValueKey('open-full-synopsis')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('synopsis-section'))).dy,
        lessThan(tester.getTopLeft(find.text(store.t('ratingTitle'))).dy),
      );
      expect(find.text('4.7'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('compact-comments-preview')),
        findsNothing,
      );
      expect(portal.communityRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline failed sends keep the draft, and an acknowledged send clears it once',
    (tester) async {
      final (store, portal) = await setup(tester);
      var accepted = false;
      portal.communityHandler = (action, args) async => action == 'comment-send'
          ? accepted
                ? {'ok': true, 'id': '55'}
                : {'ok': false, 'code': 'rejected'}
          : commentPageJson();
      await mount(
        tester,
        CommentsPage(store: store, videoId: '20', title: '測試動畫'),
      );
      await tester.enterText(find.byType(TextField), '這是一份離線草稿');
      await frames(tester);
      await tester.tap(find.byIcon(CupertinoIcons.arrow_up_circle_fill));
      await frames(tester);
      expect(find.text('這是一份離線草稿'), findsOneWidget);
      expect(find.text(store.t('communityRejected')), findsOneWidget);
      accepted = true;
      await tester.tap(find.byIcon(CupertinoIcons.arrow_up_circle_fill));
      await frames(tester);
      expect(find.text('這是一份離線草稿'), findsNothing);
      expect(
        portal.communityRequests
            .where((r) => r['action'] == 'comment-send')
            .length,
        2,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'official folded content remains hidden until expanded and reply reads use the parent comment',
    (tester) async {
      final (store, portal) = await setup(tester);
      portal.communityHandler = (action, args) async => action == 'replies'
          ? {
              'ok': true,
              'comments': [commentJson('2')],
            }
          : {
              ...commentPageJson(),
              'comments': [
                {
                  ...commentJson('1'),
                  'text': '官方折疊的內容',
                  'folded': true,
                  'replies': 1,
                },
              ],
            };
      await mount(
        tester,
        CommentsPage(store: store, videoId: '20', title: '測試動畫'),
      );
      expect(find.text('官方折疊的內容'), findsNothing);
      await tester.tap(find.text(store.t('foldedComment')));
      await frames(tester);
      expect(find.text('官方折疊的內容'), findsOneWidget);
      await tester.tap(find.byIcon(CupertinoIcons.chat_bubble));
      await frames(tester);
      expect(portal.communityRequests.last['commentId'], '1');
      expect(find.byKey(const ValueKey('comment-2')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'player preview shows official rating and a comment before expanding',
    (tester) async {
      final (store, portal) = await setup(tester);
      portal.communityResponse = commentPageJson();
      await mount(
        tester,
        CompactCommentsPreview(
          store: store,
          videoId: '20',
          title: '測試動畫',
          rating: RatingSummary.fromJson({
            'value': 4.7,
            'count': 894,
            'distribution': [23, 15, 42, 81, 733],
          }),
        ),
      );
      expect(
        find.byKey(const ValueKey('compact-comments-preview')),
        findsOneWidget,
      );
      expect(find.text('4.7'), findsOneWidget);
      expect(find.text(store.t('viewAllRatings')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('comments-preview-heading')));
      await frames(tester);
      expect(find.byKey(const ValueKey('comments-page')), findsOneWidget);
      expect(find.text(store.t('messageBoard')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('board follows the current episode without an episode selector', (
    tester,
  ) async {
    final (store, portal) = await setup(tester);
    portal.communityHandler = (action, args) async =>
        commentPageJson(id: args['videoId'] == '20' ? '1' : '2');
    var videoId = '20';
    late StateSetter update;
    await mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return CompactCommentsPreview(
            store: store,
            videoId: videoId,
            title: '測試動畫',
            episodes: const [
              Episode(id: '20', label: '1'),
              Episode(id: '21', label: '2'),
            ],
          );
        },
      ),
    );
    expect(find.byKey(const ValueKey('preview-comment-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('board-episode-selector')), findsNothing);
    update(() => videoId = '21');
    await frames(tester);
    expect(find.byKey(const ValueKey('preview-comment-1')), findsNothing);
    expect(find.byKey(const ValueKey('preview-comment-2')), findsOneWidget);
    expect(portal.communityRequests.last['videoId'], '21');
    await tester.tap(find.byKey(const ValueKey('open-full-comments')));
    await frames(tester);
    expect(portal.communityRequests.last['videoId'], '21');
    expect(find.byKey(const ValueKey('board-episode-selector')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'avatar and attachment bytes decode in the preview and the attachment viewer',
    (tester) async {
      final (store, portal) = await setup(tester);
      const avatar = 'https://avatar2.bahamut.com.tw/test-avatar.png';
      const image = 'https://wall.bahamut.com.tw/test-attachment.png';
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawColor(const Color(0xff67b8d3), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final decoded = await picture.toImage(64, 64);
        for (final url in [avatar, image]) {
          PaintingBinding.instance.imageCache.putIfAbsent(
            NetworkImage(url),
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: decoded.clone())),
            ),
          );
        }
        decoded.dispose();
        picture.dispose();
      });
      portal.communityResponse = {
        ...commentPageJson(),
        'comments': [
          {...commentJson('1'), 'avatar': avatar, 'image': image},
        ],
      };
      await mount(
        tester,
        CompactCommentsPreview(store: store, videoId: '20', title: '測試動畫'),
      );
      bool decoded(Finder parent) => find
          .descendant(of: parent, matching: find.byType(RawImage))
          .evaluate()
          .any((element) => (element.widget as RawImage).image != null);
      expect(decoded(find.byType(CommentAvatar)), isTrue);
      expect(decoded(find.byType(CommentAttachment)), isTrue);
      await tester.tap(find.byKey(const ValueKey('comment-attachment-$image')));
      await frames(tester);
      expect(
        find.byKey(const ValueKey('comment-image-viewer')),
        findsOneWidget,
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(decoded(find.byType(InteractiveViewer)), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inline comments scroll horizontally in official order with a button below',
    (tester) async {
      final (store, portal) = await setup(tester);
      const order = [
        '8',
        '3',
        '17',
        '2',
        '9',
        '30',
        '1',
        '24',
        '6',
        '25',
        '77',
        '88',
      ];
      portal.communityResponse = {
        ...commentPageJson(nextPage: 2),
        'comments': [
          for (final id in order)
            {...commentJson(id), 'text': '官方建議順序的留言 $id。這段內容保留在詳情頁預覽中。'},
        ],
      };
      await mount(
        tester,
        CompactCommentsPreview(store: store, videoId: '20', title: '測試動畫'),
      );
      final list = find.byKey(const ValueKey('inline-comments-20'));
      final openAll = find.byKey(const ValueKey('open-full-comments'));
      expect(tester.getSize(list).height, lessThan(330));
      expect(
        tester.widget<SingleChildScrollView>(list).scrollDirection,
        Axis.horizontal,
      );
      expect(
        find.byKey(const ValueKey('preview-comment-8')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('preview-comment-8'))).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('preview-comment-3'))).dx,
        ),
      );
      expect(openAll.hitTestable(), findsOneWidget);
      for (
        var step = 0;
        step < 20 &&
            find.byKey(const ValueKey('preview-comment-25')).evaluate().isEmpty;
        step++
      ) {
        await tester.drag(list, const Offset(-300, 0));
        await frames(tester);
      }
      expect(openAll.hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-comment-25')), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-comment-77')), findsNothing);
      expect(find.byKey(const ValueKey('preview-comment-88')), findsNothing);
      expect(tester.widget(openAll), isA<GlassButton>());
      expect(portal.communityRequests.length, 1);
      expect(portal.communityRequests.single['order'], 1);
      expect(portal.communityRequests.single['page'], 0);
      await tester.tap(openAll);
      await frames(tester);
      expect(find.byKey(const ValueKey('comments-page')), findsOneWidget);
      expect(portal.communityRequests.length, 2);
      expect(portal.communityRequests.last['order'], 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preview cards fit short and long comments', (tester) async {
    final (store, portal) = await setup(tester);
    final longText = List.filled(12, '這是一段比較長的留言內容。').join();
    portal.communityResponse = {
      ...commentPageJson(),
      'comments': [
        {...commentJson('1'), 'text': '短留言'},
        {...commentJson('2'), 'text': longText},
      ],
    };
    await mount(
      tester,
      SingleChildScrollView(
        child: CompactCommentsPreview(
          store: store,
          videoId: '20',
          title: '測試動畫',
        ),
      ),
    );
    final short = find.byKey(const ValueKey('preview-comment-1'));
    final long = find.byKey(const ValueKey('preview-comment-2'));
    expect(tester.getSize(short).height, lessThan(tester.getSize(long).height));
    expect(tester.widget<Text>(find.text(longText)).maxLines, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'notification center shows subscribed updates and supports read filtering',
    (tester) async {
      final (store, portal) = await setup(tester);
      portal.communityResponse = {
        'ok': true,
        'owner': 'reader',
        'items': [notificationJson('20'), notificationJson('21')],
      };
      await mount(tester, NotificationsPage(store: store));
      expect(find.byKey(const ValueKey('notification-20')), findsOneWidget);
      expect(find.text(store.t('notifications')), findsOneWidget);
      expect(store.unreadNotifications, 2);
      await tester.tap(find.bySemanticsLabel(store.t('markAllRead')));
      await frames(tester);
      expect(store.unreadNotifications, 0);
      await tester.tap(find.text('${store.t('unread')} 0'));
      await frames(tester);
      expect(find.text(store.t('noUnreadNotifications')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'danmaku settings and composer remain usable on a small display with large text',
    (tester) async {
      final (store, portal) = await setup(tester);
      tester.view.physicalSize = const Size(320, 640);
      store.playingAnime = const Anime(
        id: '10',
        title: '測試動畫',
        cover: 'https://p2.bahamut.com.tw/10.jpg',
      );
      store.playingVideoId = '20';
      store.playback.value = const PlaybackState(
        phase: PlaybackPhase.content,
        surfaceReady: true,
        duration: 1200,
      );
      // A real send remains disabled without an active player operation.
      portal.communityResponse = {'ok': false, 'code': 'rejected'};
      await mount(tester, DanmakuPanel(store: store), scale: 1.8);
      expect(find.byType(GlassSlider), findsNWidgets(2));
      await mount(
        tester,
        DanmakuPanel(store: store, composerOnly: true),
        scale: 1.8,
      );
      await tester.enterText(find.byType(TextField), '離線草稿');
      expect(find.text('離線草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('render community interface previews in both appearances', (
    tester,
  ) async {
    final (store, portal) = await setup(tester);
    await tester.runAsync(() async {
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final font in manifest) {
        final loader = FontLoader(font['family'] as String);
        for (final asset in font['fonts'] as List) {
          loader.addFont(rootBundle.load(asset['asset'] as String));
        }
        await loader.load();
      }
    });
    final comments = {
      ...commentPageJson(),
      'comments': [
        {
          ...commentJson('1'),
          'name': '星野',
          'text': '這一集的光影好漂亮，最後那段配樂也太溫柔了。',
          'likes': 28,
          'replies': 3,
        },
        {
          ...commentJson('2'),
          'name': '夏日放映室',
          'text': '每個星期最期待的時刻。看完又想從第一集重新開始。',
          'likes': 16,
        },
      ],
    };
    final previewComments = {
      ...comments,
      'comments': [
        ...(comments['comments'] as List),
        for (var index = 3; index <= 12; index++)
          {
            ...commentJson('$index'),
            'name': '星光旅人 $index',
            'text': '這段旅程有好多細節值得回看，期待下一集繼續相遇。',
            'time': '$index 天前',
          },
      ],
    };
    final output = Directory('../artifacts/community-previews')
      ..createSync(recursive: true);
    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('community-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${output.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    final notifications = {
      'ok': true,
      'owner': 'reader',
      'items': [
        {...notificationJson('20'), 'title': '星光下的旅程 [6] 更新囉！'},
        {
          ...notificationJson('21'),
          'title': '轉生之後，繼續冒險 第二季 [5] 更新囉！',
          'time': '2天前',
        },
      ],
    };
    for (final brightness in Brightness.values) {
      portal.communityResponse = previewComments;
      await mount(
        tester,
        Builder(
          builder: (context) => GlassScaffold(
            extendBody: false,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
              child: CompactCommentsPreview(
                store: store,
                videoId: '20',
                title: '星光下的旅程 · 第 6 集',
                rating: RatingSummary.fromJson({
                  'value': 4.7,
                  'count': 894,
                  'distribution': [23, 15, 42, 81, 733],
                }),
              ),
            ),
          ),
        ),
        brightness: brightness,
      );
      await capture('comment-preview-${brightness.name}');
      final openAll = find.byKey(const ValueKey('open-full-comments'));
      await tester.ensureVisible(openAll);
      await frames(tester);
      expect(openAll.hitTestable(), findsOneWidget);
      await capture('comment-preview-end-${brightness.name}');
      await tester.pumpWidget(const SizedBox());
      portal.communityResponse = comments;
      await mount(
        tester,
        CommentsPage(store: store, videoId: '20', title: '星光下的旅程 · 第 6 集'),
        brightness: brightness,
      );
      await capture('comments-${brightness.name}');
      await tester.pumpWidget(const SizedBox());
      portal.communityResponse = notifications;
      await mount(
        tester,
        NotificationsPage(store: store),
        brightness: brightness,
      );
      await capture('notifications-${brightness.name}');
      await tester.pumpWidget(const SizedBox());
      await mount(tester, DanmakuPanel(store: store), brightness: brightness);
      await capture('danmaku-${brightness.name}');
      await tester.pumpWidget(const SizedBox());
    }
    expect(tester.takeException(), isNull);
  });
}
