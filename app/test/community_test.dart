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
