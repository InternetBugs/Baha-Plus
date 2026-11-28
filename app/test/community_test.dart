import 'fake_playback.dart';
import 'fake_metadata.dart';
import 'native_danmaku_sender_test.dart' show DanmakuSendFixture;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/app_diagnostics.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

Json commentJson(String id) => {
  'id': id,
  'name': '讀者',
  'userId': 'reader',
  'text': '故事與心得',
  'time': '1天前',
  'likes': 3,
  'dislikes': 0,
  'replies': 0,
  'vote': 0,
  'folded': false,
};
Json commentPageJson({String id = '1', int nextPage = 0}) => {
  'ok': true,
  'messageId': '123',
  'total': 15,
  'nextPage': nextPage,
  'comments': [commentJson(id)],
};
Json notificationJson(String id) => {
  'id': 'episode:$id',
  'title': '測試動畫 [$id] 更新囉！',
  'videoId': id,
  'time': '1天前',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<(AppStore, FakePortal, MemoryStorage)> setup({
    AppDiagnostics? diagnostics,
  }) async {
    final disk = MemoryStorage();
    final portal = FakePortal();
    final store = await AppStore.create(
      nativeHttpApiFactory: PendingNativeHttpApi.new,
      metadataApi: FakeMetadata(),
      accountApi: portal.accountApi,
      danmakuSender: DanmakuSendFixture().sender,
      storage: disk,
      animeSearch: FakeSearch(),
      diagnostics: diagnostics,
    );
    addTearDown(store.dispose);
    await store.attach(portal);
    store.accountProfile = const AccountProfile(
      id: 'reader',
      displayName: '讀者',
    );
    return (store, portal, disk);
  }

  test(
    'typed comments preserve folded rows and reject invalid IDs, counts, duplicates and artwork',
    () {
      final page = CommentPage.fromJson(commentPageJson());
      expect(page.comments.single.id, '1');
      expect(page.messageId, '123');
      expect(
        () => CommentPage.fromJson({...commentPageJson(), 'nextPage': -1}),
        throwsFormatException,
      );
      expect(
        () => OfficialComment.fromJson({
          ...commentJson('1'),
          'image': 'https://attacker.test/x.jpg',
        }),
        throwsFormatException,
      );
      expect(
        () => CommentPage.fromJson({
          ...commentPageJson(),
          'comments': [commentJson('1'), commentJson('1')],
        }),
        throwsFormatException,
      );
      expect(
        () => AnimeNotification.fromJson({
          ...notificationJson('20'),
          'videoId': 'bad',
        }),
        throwsFormatException,
      );
    },
  );

  test('votes toggle and switch sides without mutating the comment', () {
    final original = OfficialComment.fromJson(commentJson('1'));
    for (final (previous, type, vote, likes, dislikes) in [
      (0, 1, 1, 4, 2),
      (0, 2, -1, 3, 3),
      (1, 1, 0, 2, 2),
      (1, 2, -1, 2, 3),
      (-1, 1, 1, 4, 1),
      (-1, 2, 0, 3, 1),
    ]) {
      final before = original.copyWith(
        vote: previous,
        dislikes: 2,
        folded: true,
      );
      final after = before.withVote(type);
      expect(
        (after.vote, after.likes, after.dislikes),
        (vote, likes, dislikes),
      );
      expect((before.vote, before.likes, before.dislikes), (previous, 3, 2));
      expect(
        (after.id, after.text, after.folded),
        (original.id, original.text, true),
      );
    }
    for (final type in [1, 2]) {
      final up = original.copyWith(likes: 0, vote: 1).withVote(type);
      final down = original.copyWith(dislikes: 0, vote: -1).withVote(type);
      expect(up.likes, 0);
      expect(down.dislikes, 0);
    }
  });

  test(
    'danmaku settings publish only scoped changes and compare by value',
    () async {
      final (store, _, _) = await setup();
      var global = 0;
      var scoped = 0;
      store.addListener(() => global++);
      store.danmakuSettingsNotifier.addListener(() => scoped++);
      final changed = store.danmakuSettings.copyWith(opacity: .5);
      final equal = DanmakuSettings.fromJson(changed.toJson());
      expect(changed, equal);
      expect(changed.hashCode, equal.hashCode);
      expect(() => changed.copyWith(scale: double.nan), throwsFormatException);
      await store.setDanmakuSettings(changed);
      await store.setDanmakuSettings(equal);
      expect(store.danmakuSettings, changed);
      expect(scoped, 1);
      expect(global, 0);
    },
  );

  test(
    'first comment pages cache by explicit sort and invalidate together',
    () async {
      final (store, portal, _) = await setup();
      portal.accountApi.communityHandler = (_, args) async =>
          commentPageJson(id: '${args['order']}');
      final chronological = await store.loadComments('20', sort: 0);
      final recommended = await store.loadComments('20', sort: 1);
      expect(store.cachedComments('20', sort: 0), same(chronological));
      expect(store.cachedComments('20', sort: 1), same(recommended));
      store.invalidateCommentsCache('20');
      expect(store.cachedComments('20', sort: 0), isNull);
      expect(store.cachedComments('20', sort: 1), isNull);
    },
  );

  test('posting requires a canonical nonzero board ID', () {
    final page = CommentPage.fromJson(commentPageJson());
    for (final id in ['1', '123', '9' * 20]) {
      expect(page.copyWith(messageId: id).canPost, isTrue);
    }
    for (final id in ['', '0', '01', '-1', '1a', '9' * 21]) {
      expect(page.copyWith(messageId: id).canPost, isFalse);
    }
    final replacement = page.copyWith(total: 0, nextPage: 2, comments: []);
    expect(replacement.messageId, page.messageId);
    expect((replacement.total, replacement.nextPage), (0, 2));
    expect(replacement.comments, isEmpty);
    expect(page.comments, hasLength(1));
  });

  test('comment pages allow 200 rows and reply threads allow 2000', () async {
    final (store, portal, _) = await setup();
    final rows = List.generate(2001, (index) => commentJson('${index + 1}'));
    expect(CommentPage.parseComments(rows.take(200).toList()), hasLength(200));
    expect(
      () => CommentPage.fromJson({
        ...commentPageJson(),
        'comments': rows.take(201).toList(),
      }),
      throwsFormatException,
    );
    portal.communityResponse = {
      'ok': true,
      'comments': rows.take(2000).toList(),
    };
    expect(await store.loadReplies('1'), hasLength(2000));
    portal.communityResponse = {'ok': true, 'comments': rows};
    await expectLater(store.loadReplies('1'), throwsFormatException);
  });

  test(
    'only first-page suggested reads populate the LRU without notifying',
    () async {
      final (store, portal, _) = await setup();
      portal.communityResponse = commentPageJson();
      final first = await store.loadComments('20');
      expect(store.cachedComments('20'), same(first));
      expect(store.cachedComments('20', order: 0), isNull);
      portal.communityResponse = commentPageJson(id: '2');
      await store.loadComments('20', page: 1);
      await store.loadComments('20', order: 0);
      store.updateCachedCommentsPage('20', first.copyWith(total: 0), order: 0);
      expect(store.cachedComments('20'), same(first));
      expect(store.commentsVersion.value, 0);

      for (var id = 21; id <= 39; id++) {
        await store.loadComments('$id');
      }
      expect(store.cachedComments('20'), same(first));
      final latest = first.copyWith(total: 2);
      store.updateCachedCommentsPage('40', latest);
      expect(store.cachedComments('40'), same(latest));
      expect(store.cachedComments('21'), isNull);
      expect(store.cachedComments('20'), same(first));
      expect(store.commentsVersion.value, 1);
      store.invalidateCommentsCache();
      expect(store.cachedComments('40'), isNull);
      expect(store.cachedComments('20'), isNull);
      expect(store.commentsVersion.value, 2);
    },
  );

  test(
    'writes update cached votes, reply counts, and preview revisions',
    () async {
      final (store, portal, _) = await setup();
      portal.communityResponse = commentPageJson();
      final first = await store.loadComments('20');
      await store.loadComments('21');
      final comment = first.comments.single;
      portal.communityResponse = {'ok': true};
      final up = await store.voteComment(comment, 1, videoId: '20');
      expect(store.cachedComments('20')!.comments.single, same(up));
      expect(store.cachedComments('21')!.comments.single.vote, 0);
      expect(comment.vote, 0);
      expect(store.commentsVersion.value, 1);
      final down = await store.voteComment(up, 2);
      for (final episode in ['20', '21']) {
        expect(store.cachedComments(episode)!.comments.single, same(down));
      }
      expect(store.commentsVersion.value, 2);
      await store.voteComment(up, 2, videoId: '22');
      expect(store.commentsVersion.value, 2);
      for (final parent in ['1', '99']) {
        await store.sendComment(
          videoId: '20',
          messageId: '123',
          text: ' reply ',
          commentId: parent,
        );
      }
      final replied = store.cachedComments('20')!.comments.single;
      expect((replied.replies, replied.vote), (1, -1));
      expect(store.cachedComments('21')!.comments.single.replies, 0);
      expect(store.commentsVersion.value, 4);
      await store.sendComment(videoId: '20', messageId: '123', text: ' new ');
      expect(store.cachedComments('20'), isNull);
      expect(store.cachedComments('21'), isNotNull);
      expect(store.commentsVersion.value, 5);
    },
  );

  test(
    'sends count trimmed Unicode characters before the account request',
    () async {
      final (store, portal, _) = await setup();
      store.accountProfile = null;
      portal.communityResponse = {'ok': true};
      final limit = '😀' * 2000;
      for (final text in ['  ', '$limit字']) {
        await expectLater(
          store.sendComment(videoId: '20', messageId: '123', text: text),
          throwsA(
            isA<CommunityException>().having(
              (error) => error.code,
              'code',
              'input',
            ),
          ),
        );
      }
      expect(portal.communityRequests, isEmpty);
      expect(store.commentsVersion.value, 0);
      await store.sendComment(
        videoId: '20',
        messageId: '123',
        text: ' $limit ',
      );
      expect(portal.communityRequests.single['text'], limit);
      expect(store.commentsVersion.value, 1);
    },
  );

  test(
    'episode drafts retain text and reply targets with LRU eviction',
    () async {
      final (store, _, _) = await setup();
      final comment = OfficialComment.fromJson(commentJson('1'));
      final draft = CommentDraft(replyThread: comment, replyTarget: comment);
      expect(const CommentDraft().isEmpty, isTrue);
      expect(const CommentDraft(text: ' ').isEmpty, isFalse);
      expect(CommentDraft(replyThread: comment).isEmpty, isFalse);
      expect(CommentDraft(replyTarget: comment).isEmpty, isFalse);
      store.saveCommentDraft('1', draft);
      for (var id = 2; id <= 30; id++) {
        store.saveCommentDraft('$id', CommentDraft(text: '$id'));
      }
      expect(store.commentDraft('1'), same(draft));
      store.saveCommentDraft('31', const CommentDraft(text: '31'));
      expect(store.commentDraft('2').isEmpty, isTrue);
      expect(store.commentDraft('3').text, '3');
      expect(store.commentDraft('1').replyTarget, same(comment));
      store.clearCommentDraft('1');
      store.saveCommentDraft('3', const CommentDraft());
      expect(store.commentDraft('1').isEmpty, isTrue);
      expect(store.commentDraft('3').isEmpty, isTrue);
      expect(store.commentsVersion.value, 0);
    },
  );

  test(
    'an invalidated or superseded preview read cannot restore old data',
    () async {
      final (store, portal, _) = await setup();
      final delayed = Completer<Json>();
      portal.communityPending = delayed;
      final older = store.loadComments('20');
      final invalidated = store.loadComments('21');
      portal.communityPending = null;
      portal.communityResponse = commentPageJson(id: '2');
      final latest = await store.loadComments('20');
      store.invalidateCommentsCache('21');
      delayed.complete(commentPageJson());
      await Future.wait([older, invalidated]);
      expect(store.cachedComments('20'), same(latest));
      expect(store.cachedComments('21'), isNull);
      expect(store.commentsVersion.value, 1);
    },
  );

  for (final transition in [
    'logout',
    'switch',
    'sync guest',
    'connect',
    'account-guest',
    'account-authenticated',
  ]) {
    test(
      '$transition clears previews and drafts when identity changes',
      () async {
        final (store, portal, _) = await setup();
        final bridge = transition.startsWith('account-');
        if (bridge) await store.connectAccount();
        portal.communityResponse = commentPageJson();
        await store.loadComments('20');
        store.saveCommentDraft('20', const CommentDraft(text: 'private'));
        if (bridge) {
          await store.receive(
            jsonEncode({
              'type': transition,
              'requestId': store.operation.id,
              if (transition == 'account-authenticated')
                'profile': {'id': 'next', 'displayName': 'Next'},
            }),
            origin: OfficialSite.home,
            source: OfficialSite.home.resolve('mygather.php'),
            isMainFrame: true,
          );
        } else if (transition == 'logout') {
          expect(await store.logoutAccount(), isTrue);
        } else if (transition == 'connect') {
          await store.connectAccount();
        } else {
          portal.accountApi.profileLoader = () async => null;
          portal.accountApi.accountLoader = () async => transition == 'switch'
              ? {
                  'profile': {'id': 'next', 'displayName': 'Next'},
                  'favorites': [],
                  'history': [],
                }
              : null;
          await store.syncAccount();
        }
        expect(store.cachedComments('20'), isNull);
        expect(store.commentDraft('20').isEmpty, isTrue);
        expect(store.commentsVersion.value, 1);
      },
    );
  }

  test(
    'late write acknowledgements leave the next account preview intact',
    () async {
      final (store, portal, _) = await setup();
      final delayed = Completer<Json>();
      portal.communityPending = delayed;
      final sending = store.sendComment(
        videoId: '20',
        messageId: '123',
        text: '留言',
      );
      final voting = store.voteComment(
        OfficialComment.fromJson(commentJson('1')),
        1,
      );
      await store.logoutAccount();
      portal.communityPending = null;
      portal.communityResponse = commentPageJson();
      final latest = await store.loadComments('20');
      delayed.complete({'ok': true});
      await sending;
      expect((await voting).vote, 1);
      expect(store.cachedComments('20'), same(latest));
      expect(store.commentsVersion.value, 0);
    },
  );

  test(
    'official rating summaries preserve the average, count and five star distribution',
    () {
      final rating = RatingSummary.fromJson({
        'value': 4.7,
        'count': 894,
        'distribution': [23, 15, 42, 81, 733],
      });
      expect(rating.value, 4.7);
      expect(rating.count, 894);
      expect(rating.distribution.last, 733);
      expect(
        () => RatingSummary.fromJson({
          'value': 5.2,
          'count': 10,
          'distribution': [0, 0, 0, 0, 10],
        }),
        throwsFormatException,
      );
      expect(
        () => RatingSummary.fromJson({
          'value': 4,
          'count': 2,
          'distribution': [0, 0, 0, 0, 3],
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'danmaku preferences validate ranges and count the official UTF-8 limit',
    () {
      const settings = DanmakuSettings();
      expect(settings.copyWith(opacity: .5).scale, 1);
      expect(settings.copyWith(enabled: false).enabled, isFalse);
      expect(() => settings.copyWith(scale: double.nan), throwsFormatException);
      expect(() => settings.copyWith(opacity: 3), throwsFormatException);
      expect(DanmakuSettings.validMessage('字' * 20), isTrue);
      expect(DanmakuSettings.validMessage('字' * 21), isFalse);
      expect(DanmakuSettings.validMessage('a' * 60), isTrue);
      expect(DanmakuSettings.validMessage('   '), isFalse);
    },
  );

  test(
    'comment reads and simulated sends preserve the active player operation and official session',
    () async {
      final (store, portal, _) = await setup();
      const anime = Anime(
        id: '10',
        title: '測試',
        cover: 'https://p2.bahamut.com.tw/10.jpg',
        latestVideoId: '20',
      );
      await playFixture(store, anime);
      final operation = store.operation.id;
      final visits = portal.visited.length;
      portal.communityResponse = commentPageJson(nextPage: 2);
      final page = await store.loadComments('20', order: 0, page: 3);
      expect(page.nextPage, 2);
      expect(portal.communityRequests.last['order'], 0);
      expect(portal.communityRequests.last['page'], 3);
      portal.communityResponse = {'ok': true, 'id': '55'};
      await store.sendComment(
        videoId: '20',
        messageId: '123',
        text: ' 留言 ',
        commentId: '2',
      );
      expect(portal.communityRequests.last['text'], '留言');
      expect(portal.communityRequests.last['owner'], 'reader');
      expect(portal.communityRequests.last['commentId'], '2');
      expect(store.operation.id, operation);
      expect(portal.visited.length, visits);
      expect(store.showsPlayer, isTrue);
    },
  );

  test(
    'native stale account reads and writes fail without replaying the request',
    () async {
      final (store, portal, _) = await setup();
      var reads = 0;
      portal.communityHandler = (action, arguments) async {
        if (action == 'comments' && ++reads == 2) return commentPageJson();
        return {'ok': false, 'code': 'stale'};
      };
      await expectLater(
        store.loadComments('20'),
        throwsA(
          isA<CommunityException>().having((e) => e.code, 'code', 'stale'),
        ),
      );
      expect(reads, 1);
      portal.communityRequests.clear();
      await expectLater(
        store.sendComment(videoId: '20', messageId: '123', text: '離線測試'),
        throwsA(
          isA<CommunityException>().having(
            (error) => error.code,
            'code',
            'stale',
          ),
        ),
      );
      expect(portal.communityRequests.length, 1);
    },
  );

  test(
    'simulated send retains rejection semantics, rejects duplicate writes and releases its lock',
    () async {
      final (store, portal, _) = await setup();
      portal.communityPending = Completer<Json>();
      final first = store.sendComment(
        videoId: '20',
        messageId: '123',
        text: '留言',
      );
      await expectLater(
        store.sendComment(videoId: '20', messageId: '123', text: '留言'),
        throwsA(
          isA<CommunityException>().having((e) => e.code, 'code', 'busy'),
        ),
      );
      expect(portal.communityRequests.length, 1);
      portal.communityPending!.complete({'ok': true, 'id': '55'});
      await first;
      portal.communityPending = null;
      portal.communityResponse = {'ok': false, 'code': 'rejected'};
      await expectLater(
        store.sendComment(videoId: '20', messageId: '123', text: '留言'),
        throwsA(
          isA<CommunityException>().having((e) => e.code, 'code', 'rejected'),
        ),
      );
      portal.communityResponse = {'ok': true};
      await store.sendComment(videoId: '20', messageId: '123', text: '留言');
      expect(portal.communityRequests.length, 3);
    },
  );

  test(
    'danmaku cannot be submitted during ads or with invalid UTF-8 length',
    () async {
      final (store, portal, _) = await setup();
      const anime = Anime(
        id: '10',
        title: '測試',
        cover: 'https://p2.bahamut.com.tw/10.jpg',
        latestVideoId: '20',
      );
      await playFixture(store, anime);
      store.playback.value = const PlaybackState(
        phase: PlaybackPhase.advertisement,
        surfaceReady: true,
        duration: 30,
      );
      await expectLater(
        store.sendDanmaku('測試'),
        throwsA(isA<CommunityException>()),
      );
      store.playback.value = const PlaybackState(
        phase: PlaybackPhase.content,
        surfaceReady: true,
        duration: 1200,
      );
      await expectLater(
        store.sendDanmaku('字' * 21),
        throwsA(isA<CommunityException>()),
      );
      expect(portal.communityRequests, isEmpty);
      portal.communityResponse = {'ok': true, 'id': '91'};
      await store.sendDanmaku('測試', position: 1, color: '#FFD166');
      expect(portal.communityRequests, isEmpty);
      expect(store.nativeHttpPlayback!.danmaku.single.text, '測試');
      expect(store.nativeHttpPlayback!.danmaku.single.mode, 'top');
    },
  );

  test('danmaku settings survive restart without browser commands', () async {
    final (store, portal, disk) = await setup();
    await store.setDanmakuSettings(
      const DanmakuSettings(opacity: .6, top: false),
    );
    final restored = await AppStore.create(
      nativeHttpApiFactory: PendingNativeHttpApi.new,
      metadataApi: FakeMetadata(),
      storage: disk,
      animeSearch: FakeSearch(),
    );
    addTearDown(restored.dispose);
    expect(restored.danmakuSettings.opacity, .6);
    expect(restored.danmakuSettings.top, isFalse);
    const anime = Anime(
      id: '10',
      title: '測試',
      cover: 'https://p2.bahamut.com.tw/10.jpg',
      latestVideoId: '20',
    );
    await playFixture(store, anime);
    expect(store.danmakuSettings.opacity, .6);
    expect(store.danmakuSettings.top, isFalse);
    expect(portal.scripts, isEmpty);
  });

  test(
    'notification read state is scoped to official account and never fabricates update items',
    () async {
      final (store, portal, disk) = await setup();
      portal.communityResponse = {
        'ok': true,
        'owner': 'reader',
        'items': [notificationJson('20'), notificationJson('21')],
      };
      await store.refreshNotifications();
      expect(store.unreadNotifications, 2);
      await store.markNotificationsRead(store.notifications.first);
      expect(store.unreadNotifications, 1);
      expect(jsonDecode(disk.values['baha.notifications.read.reader']!), [
        'episode:20',
      ]);
      await store.refreshNotifications();
      expect(store.unreadNotifications, 1);
      portal.communityResponse = {
        'ok': true,
        'owner': 'other',
        'items': [notificationJson('22')],
      };
      await store.refreshNotifications();
      expect(store.notificationsError, 'login');
      expect(store.notifications, isEmpty);
      expect(store.unreadNotifications, 0);
      expect(disk.values.containsKey('baha.notifications.read.other'), isFalse);
    },
  );

  test(
    'notification diagnostics record outcomes without account or item content',
    () async {
      final root = await Directory.systemTemp.createTemp('baha-notifications-');
      final diagnostics = AppDiagnostics(
        directoryLoader: () async => root,
        metadataLoader: () async => {},
      );
      addTearDown(() async {
        await diagnostics.flush();
        diagnostics.dispose();
        await root.delete(recursive: true);
      });
      final (store, portal, _) = await setup(diagnostics: diagnostics);
      await diagnostics.start();
      portal.communityResponse = {
        'ok': true,
        'owner': 'reader',
        'items': [notificationJson('20')],
      };
      await store.refreshNotifications();
      portal.communityResponse = {'ok': false, 'code': 'network'};
      await store.refreshNotifications();
      expect(store.notificationsError, 'network');
      expect(store.notifications, hasLength(1));
      expect(store.notificationsLoading, isFalse);
      await diagnostics.stop();
      final report = await (await diagnostics.export()).readAsString();
      expect(report, contains('"event":"notifications.started"'));
      expect(report, contains('"event":"notifications.completed"'));
      expect(report, contains('"count":1'));
      expect(report, contains('"event":"notifications.failed"'));
      expect(report, contains('"code":"network"'));
      expect(report, isNot(contains('reader')));
      expect(report, isNot(contains('episode:20')));
      expect(report, isNot(contains('測試動畫')));
    },
  );

  test(
    'switching accounts invalidates an in-flight notification refresh',
    () async {
      final (store, portal, _) = await setup();
      portal.communityPending = Completer<Json>();
      final loading = store.refreshNotifications();
      await store.connectAccount();
      portal.communityPending!.complete({
        'ok': true,
        'owner': 'reader',
        'items': [notificationJson('20')],
      });
      await loading;
      expect(store.notifications, isEmpty);
      expect(store.notificationsLoading, isFalse);
    },
  );

  test(
    'notification navigation preserves distinct series and episode identities',
    () async {
      final (store, portal, _) = await setup();
      portal.communityResponse = {
        'ok': true,
        'anime': {
          'id': '10',
          'title': '測試',
          'cover': 'https://p2.bahamut.com.tw/10.jpg',
          'latestVideoId': '20',
          'sections': <String>[],
        },
      };
      await store.openNotification(
        AnimeNotification.fromJson(notificationJson('20')),
      );
      expect(store.playingAnime?.id, '10');
      expect(store.playingVideoId, '20');
      expect(store.nativeHttpPlayback!.videoId, '20');
      expect(store.needsOfficialPortal, isFalse);
      expect(portal.visited, isEmpty);
    },
  );
}
