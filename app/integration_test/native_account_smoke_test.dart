import 'dart:convert';

import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_account_api.dart';
import 'package:baha_plus/data/official_http_client.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

import '../test/core_test.dart' show FakeSearch, MemoryStorage;
import '../test/fake_metadata.dart';
import '../test/native_account_api_test.dart'
    show AccountFixture, accountAnime, nativeError;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native account cookie access, favorites and community writes without WebView',
    (tester) async {
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
      final manager = CookieManager.instance();
      final cookieUrl = WebUri('https://ani.gamer.com.tw/');
      const cookieName = 'baha_plus_native_account_probe';
      final fixture = AccountFixture()
        ..owner = 'offline-probe'
        ..saved = true;
      final requests = <http.Request>[];
      var rejectVote = false, changeCookie = false;
      final api = NativeAccountApi(
        transport: OfficialHttpClient(
          client: MockClient((request) async {
            requests.add(request);
            expect(
              request.headers['cookie']
                  ?.split('; ')
                  .contains('$cookieName=offline-probe'),
              isTrue,
            );
            if (request.url.host == 'wall.gamer.com.tw' &&
                request.method == 'POST') {
              final token = request.headers['x-bahamut-csrf-token'];
              expect(token, matches(RegExp(r'^[0-9a-f]{16}$')));
              expect(
                request.headers['cookie'],
                contains('ckBahamutCsrfToken=$token'),
              );
            }
            if (changeCookie && request.url.path == '/ajax/getCSRFToken.php') {
              await manager.setCookie(
                url: cookieUrl,
                name: cookieName,
                value: 'changed-probe',
                domain: '.gamer.com.tw',
                path: '/',
                isSecure: true,
                isHttpOnly: true,
              );
            }
            if (rejectVote && request.url.path == '/app/v1/comment_like.php') {
              return http.Response('{"error":"offline-rejection"}', 200);
            }
            if (request.url.path == '/ajax/want2play.php') {
              fixture.saved = true;
            }
            if (request.url.path == '/ajax/delgather.php') {
              fixture.saved = false;
            }
            return fixture.response(request);
          }),
        ),
      );
      final store = await AppStore.create(
        storage: MemoryStorage(),
        metadataApi: FakeMetadata(),
        animeSearch: FakeSearch(),
        accountApi: api,
      );
      try {
        expect(
          await manager.setCookie(
            url: cookieUrl,
            name: cookieName,
            value: 'offline-probe',
            domain: '.gamer.com.tw',
            path: '/',
            isSecure: true,
            isHttpOnly: true,
          ),
          isTrue,
        );
        final document = store.operation.id;
        await store.syncAccount();
        expect(store.accountProfile?.id, 'offline-probe');
        expect(store.favorites.single.id, accountAnime.id);
        expect(store.history.single.progress, .5);
        await store.toggleFavorite(accountAnime);
        expect(store.favorites, isEmpty);
        await store.toggleFavorite(accountAnime);
        expect(store.favorites.single.id, accountAnime.id);
        final comments = await store.loadComments('20');
        expect(comments.comments, hasLength(2));
        expect(
          await store.loadReplies(comments.comments.first.id),
          hasLength(1),
        );
        await store.sendComment(
          videoId: '20',
          messageId: comments.messageId,
          text: 'offline mock only',
        );
        await store.voteComment(comments.comments.first, 1);
        await store.voteComment(comments.comments.last, 2);
        rejectVote = true;
        await expectLater(
          store.voteComment(comments.comments.last, 2),
          throwsA(nativeError('rejected')),
        );
        await store.refreshNotifications();
        expect(store.notifications.single.videoId, '20');
        final before = requests.where((r) => r.method == 'POST').length;
        changeCookie = true;
        await expectLater(
          api.setFavorite(
            accountAnime,
            false,
            owner: 'offline-probe',
            checkCurrent: () {},
          ),
          throwsA(isA<CommunityException>()),
        );
        expect(requests.where((r) => r.method == 'POST').length, before);
        expect(store.operation.id, document);
        expect(store.needsOfficialPortal, isFalse);
        expect(find.byType(InAppWebView, skipOffstage: false), findsNothing);
        binding.reportData = {
          'nativeHttpOnlyCookieRead': true,
          'accountHistoryAndFavorites': true,
          'favoriteAddAndRemove': true,
          'commentsRepliesAndNotifications': true,
          'mockedCommentAndVotes': true,
          'rejectionHandled': true,
          'cookieChangeStopsWrite': true,
          'httpRequestsMocked': requests.length,
          'noWebView': true,
          'realPublications': 0,
        };
        debugPrint('BAHA_NATIVE_ACCOUNT ${jsonEncode(binding.reportData)}');
      } finally {
        store.dispose();
        await manager.deleteCookie(
          url: cookieUrl,
          name: cookieName,
          domain: '.gamer.com.tw',
          path: '/',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
