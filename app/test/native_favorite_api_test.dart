import 'dart:async';

import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/device_storage.dart';
import 'package:baha_plus/data/native_account_api.dart';
import 'package:baha_plus/data/native_http_api.dart';
import 'package:baha_plus/data/official_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_metadata.dart';

const _anime = Anime(id: '10', title: 'Favorite test', cover: '');

Matcher _error(String code) =>
    isA<CommunityException>().having((error) => error.code, 'code', code);

class _Storage implements DeviceStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> clearAccountData() async => values.removeWhere(
    (key, _) =>
        key.startsWith('baha.account.') ||
        key.startsWith('baha.notifications.read.'),
  );
}

class _FavoriteFixture {
  bool saved = true, applyMutation = true, modern = false;
  String owner = 'reader', cookie = 'initial';
  String removalResponse = '{"error":0}';
  String addResponse = '<response><okMsg>OK</okMsg></response>';
  FutureOr<void> Function(http.Request)? onRequest;
  final requests = <http.Request>[];

  late final api = NativeAccountApi(
    transport: OfficialHttpClient(
      cookieLoader: () async {
        final jar = NativeHttpCookieJar(allowedHosts: OfficialHttpClient.hosts);
        jar.receive(
          Uri.https('ani.gamer.com.tw', '/'),
          'session=$cookie; Domain=gamer.com.tw; Path=/; Secure; HttpOnly',
        );
        return jar;
      },
      client: MockClient((request) async {
        requests.add(request);
        await onRequest?.call(request);
        final text = switch (request.url.path) {
          // Use server-rendered identity; the official menu requires JS.
          '/mygather.php' =>
            '<h2 class="theme-title">我的動畫</h2>'
                '<a href="/viewList.php?u=$owner">觀看紀錄</a>',
          '/search.php' =>
            '''
<button class="ordered" onclick="animefun.toggleGather(800, 11, this, 'ordered')"></button>
<button class="${saved ? (modern ? 'btn-is-active' : 'ordered') : ''}"
 onclick="animefun.toggleGather(900, 10, this, '${modern ? 'btn-is-active' : 'ordered'}')"></button>
''',
          '/ajax/getCSRFToken.php' => 'favorite-test-csrf',
          '/ajax/delgather.php' => _mutate(false, removalResponse),
          '/ajax/want2play.php' => _mutate(true, addResponse),
          _ => throw StateError('Unexpected endpoint ${request.url.path}'),
        };
        return http.Response(
          text,
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
    ),
  );

  String _mutate(bool desired, String response) {
    if (applyMutation) saved = desired;
    return response;
  }

  Iterable<http.Request> get posts =>
      requests.where((request) => request.method == 'POST');
  Iterable<http.Request> get searches =>
      requests.where((request) => request.url.path == '/search.php');

  Future<void> set(bool desired) =>
      api.setFavorite(_anime, desired, owner: 'reader', checkCurrent: () {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final modern in [false, true]) {
    for (final response in [
      '{"error":0}',
      '{"error":"0"}',
      '{"error":-1}',
      '{"error":null}',
      '{"error":false}',
      '{"msg":"ok"}',
      'true',
      '',
      'changed-format',
    ]) {
      test(
        '${modern ? 'modern' : 'legacy'} removal confirms server state for ${response.isEmpty ? 'empty response' : response}',
        () async {
          final fixture = _FavoriteFixture()
            ..modern = modern
            ..removalResponse = response;
          addTearDown(fixture.api.dispose);
          await fixture.set(false);
          expect(fixture.saved, isFalse);
          expect(fixture.posts.single.url.path, '/ajax/delgather.php');
          expect(fixture.posts.single.bodyFields['s'], '900');
          expect(fixture.posts.single.bodyFields['animeSn'], '10');
          expect(fixture.searches, hasLength(2));
          expect(
            fixture.requests.last.url.path,
            '/mygather.php',
            reason: 'The confirmed state must still belong to the same owner.',
          );
        },
      );
    }
  }

  for (final response in [
    '{"error":0}',
    '{"error":null}',
    '{}',
    '',
    'changed-format',
  ]) {
    test(
      'removal does not accept an unchanged server state: $response',
      () async {
        final fixture = _FavoriteFixture()
          ..removalResponse = response
          ..applyMutation = false;
        addTearDown(fixture.api.dispose);
        await expectLater(fixture.set(false), throwsA(_error('rejected')));
        expect(fixture.saved, isTrue);
        expect(fixture.posts, hasLength(1));
        expect(fixture.searches, hasLength(2));
      },
    );
  }

  for (final response in [
    '{"error":1}',
    '{"error":"2"}',
    '{"error":true}',
    '{"error":"invalid"}',
    '{"error":{"code":1}}',
    '{"error":"NaN"}',
    '{"error":"Infinity"}',
  ]) {
    test('explicit removal errors remain failures: $response', () async {
      final fixture = _FavoriteFixture()..removalResponse = response;
      addTearDown(fixture.api.dispose);
      await expectLater(fixture.set(false), throwsA(_error('rejected')));
      expect(fixture.posts, hasLength(1));
      expect(fixture.searches, hasLength(1));
    });
  }

  test(
    'adding also requires the server state to match the acknowledgement',
    () async {
      final fixture = _FavoriteFixture()
        ..saved = false
        ..applyMutation = false;
      addTearDown(fixture.api.dispose);
      await expectLater(fixture.set(true), throwsA(_error('rejected')));
      expect(fixture.posts.single.url.path, '/ajax/want2play.php');
      expect(fixture.searches, hasLength(2));
    },
  );

  for (final saved in [false, true]) {
    test(
      'already desired state $saved does not submit another mutation',
      () async {
        final fixture = _FavoriteFixture()..saved = saved;
        addTearDown(fixture.api.dispose);
        await fixture.set(saved);
        expect(fixture.posts, isEmpty);
        expect(fixture.requests.map((request) => request.url.path), [
          '/mygather.php',
          '/search.php',
          '/mygather.php',
        ]);
      },
    );
  }

  for (final change in ['owner', 'cookie']) {
    test(
      '$change change after mutation cannot confirm another session',
      () async {
        final fixture = _FavoriteFixture();
        addTearDown(fixture.api.dispose);
        fixture.onRequest = (request) {
          if (request.method == 'POST') {
            if (change == 'owner') fixture.owner = 'another';
            if (change == 'cookie') fixture.cookie = 'changed';
          }
        };
        await expectLater(fixture.set(false), throwsA(_error('stale')));
        expect(fixture.posts, hasLength(1));
      },
    );
  }

  test('a different initial owner cannot send a favorite mutation', () async {
    final fixture = _FavoriteFixture()..owner = 'another';
    addTearDown(fixture.api.dispose);
    await expectLater(fixture.set(false), throwsA(_error('stale')));
    expect(fixture.posts, isEmpty);
    expect(fixture.searches, isEmpty);
  });

  Future<AppStore> createStore(_FavoriteFixture fixture) async {
    final store = await AppStore.create(
      storage: _Storage(),
      metadataApi: FakeMetadata(),
      accountApi: fixture.api,
    );
    addTearDown(store.dispose);
    store.accountProfile = const AccountProfile(
      id: 'reader',
      displayName: 'Reader',
    );
    store.favorites = [_anime];
    return store;
  }

  for (final response in ['{"error":"0"}', '{}', '']) {
    test(
      'store shows confirmed removal instead of an error for $response',
      () async {
        final fixture = _FavoriteFixture()..removalResponse = response;
        final store = await createStore(fixture);
        final document = store.operation.id;
        await store.toggleFavorite(_anime);
        expect(store.isFavorite(_anime), isFalse);
        expect(store.notice, store.t('removed'));
        expect(store.accountNeedsRefresh, isTrue);
        expect(store.operation.id, document);
        expect(store.needsOfficialPortal, isFalse);
        expect(fixture.posts, hasLength(1));
      },
    );
  }

  test('store retains its favorite when the removal was not applied', () async {
    final fixture = _FavoriteFixture()..applyMutation = false;
    final store = await createStore(fixture);
    await store.toggleFavorite(_anime);
    expect(store.isFavorite(_anime), isTrue);
    expect(store.notice, store.t('accountSyncError'));
    expect(fixture.posts, hasLength(1));
  });

  test(
    'store deduplicates removal while the confirmation is pending',
    () async {
      final fixture = _FavoriteFixture()..removalResponse = '{}';
      final store = await createStore(fixture);
      final waiting = Completer<void>(), release = Completer<void>();
      fixture.onRequest = (request) async {
        if (request.method == 'POST') {
          waiting.complete();
          await release.future;
        }
      };
      final first = store.toggleFavorite(_anime);
      await waiting.future;
      await store.toggleFavorite(_anime);
      expect(fixture.posts, hasLength(1));
      expect(store.isFavorite(_anime), isTrue);
      release.complete();
      await first;
      expect(fixture.posts, hasLength(1));
      expect(store.isFavorite(_anime), isFalse);
      expect(store.notice, store.t('removed'));
    },
  );
}
