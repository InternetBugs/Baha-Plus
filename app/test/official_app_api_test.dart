import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baha_plus/data/official_app_api.dart';
import 'package:baha_plus/data/official_user_agent.dart';
import 'package:baha_plus/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Synthetic values matching the anonymous v4 response, not captured accounts.
Map<String, dynamic> videoJson() => {
  'videoSn': 20,
  'animeSn': 10,
  'title': '測試動畫 [1]',
  'duration': 24,
  'rating': 3,
  'ratingDesc': '測試分級說明',
  'quality': 'FHD',
  'breakpoint': <String, dynamic>{},
};

Json catalogJson() => {
  'newAnime': {
    'date': [
      {
        'animeSn': '10',
        'videoSn': '20',
        'title': '測試動畫',
        'cover': 'https://p2.bahamut.com.tw/episode.jpg',
        'week': '7',
        'upTime': '12/31',
        'upTimeHours': '23:30',
        'volume': '第1集',
        'popular': '12345',
        'favorite': true,
      },
    ],
  },
  'hotAnime': [
    {
      'animeSn': '10',
      'videoSn': '0',
      'title': '測試動畫',
      'cover': 'https://p2.bahamut.com.tw/poster.jpg',
      'info': '年份：2026/10 共 12 集',
      'popular': '12345',
    },
  ],
  'newAdded': <dynamic>[],
  'continueWatch': [
    {'ignoredAccountState': true},
  ],
};

Json animeJson() => {
  'animeSn': 10,
  'title': '測試動畫 [1]',
  'cover': 'https://p2.bahamut.com.tw/poster.jpg',
  'content': '作品簡介。＜STAFF＞製作人員',
  'seasonStart': '2026/10/01',
  'score': 4.3,
  'tags': ['奇幻'],
  'director': '測試導演',
  'maker': '測試製作',
  'publisher': '測試代理',
  'episodes': {
    '0': [
      {'videoSn': 20, 'episode': 1, 'state': 1},
      {'videoSn': 21, 'episode': 2, 'state': 0},
    ],
    '1': [
      {'videoSn': 22, 'episode': '特別篇'},
    ],
  },
};

http.Response jsonResponse(dynamic body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

TypeMatcher<OfficialAppApiException> apiError(String code) =>
    isA<OfficialAppApiException>().having((error) => error.code, 'code', code);

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

void main() {
  test('catalog keeps timeline fields while merging poster sections', () {
    final catalog = OfficialAppMetadata.catalog(
      catalogJson(),
      now: DateTime.utc(2027, 1, 1),
    );
    final anime = catalog.items.single;
    expect(anime.id, '10');
    expect(anime.latestVideoId, '20');
    expect(anime.sections, ['season', 'hot']);
    expect(anime.cover, 'https://p2.bahamut.com.tw/episode.jpg');
    expect(anime.poster, 'https://p2.bahamut.com.tw/poster.jpg');
    expect(anime.updateDate, '2026-12-31');
    expect(anime.updateTime, '23:30');
    expect(anime.updateDay, 0);
    expect(anime.year, '2026/10');
    expect(catalog.encode(), isNot(contains('favorite')));
    expect(catalog.encode(), isNot(contains('ignoredAccountState')));
  });

  test(
    'catalog parses seasonal popularity ranking, newly added dates, and merged curated collections',
    () {
      final data = {
        'newAnime': {
          'date': [
            {
              'animeSn': '10',
              'videoSn': '20',
              'title': '最新上架新番',
              'cover': 'https://p2.bahamut.com.tw/ep-10.jpg',
              'week': '7',
              'upTime': '11/26',
              'upTimeHours': '01:00',
              'volume': '第8集',
              'popular': '5000',
            },
            {
              'animeSn': '11',
              'videoSn': '21',
              'title': '人氣冠軍新番',
              'cover': 'https://p2.bahamut.com.tw/ep-11.jpg',
              'week': '6',
              'upTime': '11/22',
              'upTimeHours': '00:30',
              'volume': '第8集',
              'popular': '192334',
            },
          ],
          'popular': [
            {'animeSn': '11'},
            {'animeSn': '10'},
            {'animeSn': '11'},
          ],
        },
        'hotAnime': <dynamic>[],
        'newAdded': [
          {
            'animeSn': '30',
            'videoSn': '0',
            'title': '劇場版 懷玉・玉折',
            'cover': 'https://p2.bahamut.com.tw/movie.jpg',
            'info': '上架日：11/24 共 1 集',
            'popular': '1604',
          },
        ],
        'category': [
          {
            'title': '音樂一下！',
            'intro': '精選音樂動畫',
            'list': [
              {
                'animeSn': '40',
                'videoSn': '0',
                'title': '孤獨搖滾！',
                'cover': 'https://p2.bahamut.com.tw/bocchi.jpg',
                'info': '年份：2022/10 共 12 集',
                'popular': '9690107',
              },
            ],
          },
          {
            'title': '12月份授權到期節目',
            'intro': '',
            'list': [
              {
                'animeSn': '50',
                'videoSn': '0',
                'title': '到期作品 A',
                'cover': 'https://p2.bahamut.com.tw/exp-a.jpg',
                'info': '年份：2014/12 共 1 集',
                'popular': '1000',
              },
            ],
          },
          {
            'title': '12月份授權到期節目',
            'intro': '',
            'list': [
              {
                'animeSn': '50',
                'videoSn': '0',
                'title': '到期作品 A',
                'cover': 'https://p2.bahamut.com.tw/exp-a.jpg',
                'info': '年份：2014/12 共 1 集',
                'popular': '1000',
              },
              {
                'animeSn': '51',
                'videoSn': '0',
                'title': '到期作品 B',
                'cover': 'https://p2.bahamut.com.tw/exp-b.jpg',
                'info': '年份：2021/01 共 13 集',
                'popular': '2000',
              },
            ],
          },
        ],
      };

      final catalog = OfficialAppMetadata.catalog(
        data,
        now: DateTime.utc(2026, 11, 26),
      );
      expect(catalog.seasonalPopularIds, ['11', '10']);
      final added = catalog.items.firstWhere((item) => item.id == '30');
      expect(added.sections, ['new']);
      expect(added.addedDate, '11/24');
      expect(added.episodeLabel, '共 1 集');

      expect(catalog.collections.length, 2);
      expect(catalog.collections.first.title, '音樂一下！');
      expect(catalog.collections.first.intro, '精選音樂動畫');
      expect(catalog.collections.first.expiring, isFalse);
      expect(catalog.collections.last.title, '12月份授權到期節目');
      expect(catalog.collections.last.expiring, isTrue);
      expect(catalog.collections.last.items.map((item) => item.id), [
        '50',
        '51',
      ]);

      final roundTripped = Catalog.fromJson(
        jsonDecode(catalog.encode()) as Json,
      );
      expect(roundTripped.seasonalPopularIds, ['11', '10']);
      expect(roundTripped.collections.length, 2);
      expect(
        roundTripped.items.firstWhere((item) => item.id == '30').addedDate,
        '11/24',
      );
    },
  );

  test(
    'catalog rolls next-year dates forward in Taipei and rejects bad dates',
    () {
      final data = catalogJson();
      final seasonal =
          ((data['newAnime'] as Json)['date'] as List).single as Json;
      seasonal['upTime'] = '01/01';
      expect(
        OfficialAppMetadata.catalog(
          data,
          now: DateTime.utc(2026, 12, 31, 12),
        ).items.single.updateDate,
        '2027-01-01',
      );
      seasonal['upTime'] = '02/30';
      expect(() => OfficialAppMetadata.catalog(data), throwsFormatException);
    },
  );

  test('invalid or empty native catalogs fail explicitly', () async {
    for (final data in [
      <String, dynamic>{},
      {
        'newAnime': {'date': []},
        'hotAnime': [],
        'newAdded': [],
      },
      catalogJson()
        ..['hotAnime'] = [
          {'animeSn': '10', 'cover': 'https://example.test/image.jpg'},
        ],
    ]) {
      final api = OfficialAppApi(
        client: MockClient((_) async => jsonResponse({'data': data})),
      );
      addTearDown(api.dispose);
      await expectLater(
        api.fetchCatalog(),
        throwsA(apiError('invalid-catalog')),
      );
    }
  });

  test(
    'video detail maps public synopsis, episodes and available metadata',
    () async {
      final api = OfficialAppApi(
        client: MockClient((request) async {
          expect(request.url.queryParameters, {'sn': '20'});
          return jsonResponse({
            'data': {'video': videoJson(), 'anime': animeJson()},
          });
        }),
      );
      addTearDown(api.dispose);
      final detail = await api.fetchDetail(animeId: '10', videoId: '20');
      expect(detail.title, '測試動畫');
      expect(detail.description, '作品簡介。');
      expect(detail.episodes.map((episode) => episode.id), ['20', '21', '22']);
      expect(detail.episodes.last.label, '特別篇');
      expect(detail.rating, isNull);
      expect(detail.metadata.any((item) => item.value == '4.3 / 5'), isTrue);
    },
  );

  test(
    'detail rejects mismatched series and repeated or absent episodes',
    () async {
      for (final anime in [
        animeJson()..['animeSn'] = 11,
        animeJson()
          ..['episodes'] = {
            '0': [
              {'videoSn': 21, 'episode': 2},
            ],
          },
        animeJson()
          ..['episodes'] = {
            '0': [
              {'videoSn': 20, 'episode': 1},
              {'videoSn': 20, 'episode': 1},
            ],
          },
      ]) {
        final api = OfficialAppApi(
          client: MockClient(
            (_) async => jsonResponse({
              'data': {'video': videoJson(), 'anime': anime},
            }),
          ),
        );
        addTearDown(api.dispose);
        await expectLater(
          api.fetchDetail(animeId: '10', videoId: '20'),
          throwsA(apiError('invalid-detail')),
        );
      }
    },
  );

  test('public search uses the same anonymous native transport', () async {
    final api = OfficialAppApi(
      client: MockClient((request) async {
        expect(request.url.path, '/anime/v1/search.php');
        expect(request.headers.containsKey('cookie'), isFalse);
        return jsonResponse({
          'data': {'animeList': []},
        });
      }),
    );
    addTearDown(api.dispose);
    expect(
      await api.fetchPublicCatalog(
        Uri.https('api.gamer.com.tw', '/anime/v1/search.php', {'kw': '測試'}),
      ),
      {
        'data': {'animeList': []},
      },
    );
    for (final uri in [
      Uri.parse('https://example.test/anime/v1/search.php'),
      Uri.parse('https://api.gamer.com.tw/mobile_app/anime/v3/token.php'),
    ]) {
      expect(
        () => api.fetchPublicCatalog(uri),
        throwsA(apiError('invalid-catalog-endpoint')),
      );
    }
  });

  test(
    'catalog and video are anonymous native GETs to verified APIs',
    () async {
      final requests = <http.Request>[];
      final api = OfficialAppApi(
        client: MockClient((request) async {
          requests.add(request);
          expect(request.method, 'GET');
          expect(request.url.origin, 'https://api.gamer.com.tw');
          expect(request.headers['Accept'], 'application/json');
          expect(request.headers['User-Agent'], OfficialUserAgent.value);
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            allOf(isNot(contains('cookie')), isNot(contains('authorization'))),
          );
          expect(request.body, isEmpty);
          expect(request.followRedirects, isFalse);
          return jsonResponse({
            'data': request.url.path.endsWith('index.php')
                ? catalogJson()
                : {'video': videoJson()},
          });
        }),
      );
      addTearDown(api.dispose);
      final catalog = await api.fetchCatalog();
      final video = await api.fetchVideo(catalog.items.first.latestVideoId!);
      expect(video.videoId, '20');
      expect(video.animeId, '10');
      expect(video.title, '測試動畫 [1]');
      expect(video.durationMinutes, 24);
      expect(video.rating, 3);
      expect(video.ratingDescription, '測試分級說明');
      expect(video.qualityLabel, 'FHD');
      expect(requests.map((request) => request.url.path), [
        '/mobile_app/anime/v4/index.php',
        '/mobile_app/anime/v4/video.php',
      ]);
      expect(requests.last.url.queryParameters, {'sn': '20'});
    },
  );

  test('server cookies are not replayed on the next request', () async {
    var count = 0;
    final api = OfficialAppApi(
      client: MockClient((request) async {
        count++;
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')),
        );
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': {'video': videoJson()},
            }),
          ),
          200,
          headers: {
            'content-type': 'application/json',
            'set-cookie': 'test-session=synthetic; Secure; HttpOnly',
          },
        );
      }),
    );
    addTearDown(api.dispose);
    await api.fetchVideo('20');
    await api.fetchVideo('20');
    expect(count, 2);
  });

  for (final invalid in [
    '',
    '0',
    '-1',
    '1.0',
    '12345678901',
    '20&token=x',
    'https://example.test/20',
  ]) {
    test('rejects invalid video ID before networking: $invalid', () async {
      final api = OfficialAppApi(
        client: MockClient((_) async => fail('Must not send a request')),
      );
      addTearDown(api.dispose);
      await expectLater(
        api.fetchVideo(invalid),
        throwsA(apiError('invalid-video-id')),
      );
    });
  }

  test('rejects metadata for a different episode', () async {
    final api = OfficialAppApi(
      client: MockClient(
        (_) async => jsonResponse({
          'data': {'video': videoJson()..['videoSn'] = 21},
        }),
      ),
    );
    addTearDown(api.dispose);
    await expectLater(api.fetchVideo('20'), throwsA(apiError('invalid-video')));
  });

  for (final entry in <String, Object?>{
    'duration': -1,
    'rating': '3',
    'animeSn': 0,
    'title': '',
    'ratingDesc': 3,
  }.entries) {
    test('rejects malformed ${entry.key}', () async {
      final api = OfficialAppApi(
        client: MockClient(
          (_) async => jsonResponse({
            'data': {'video': videoJson()..[entry.key] = entry.value},
          }),
        ),
      );
      addTearDown(api.dispose);
      await expectLater(
        api.fetchVideo('20'),
        throwsA(apiError('invalid-video')),
      );
    });
  }

  test(
    'ignores account breakpoint data when reading public metadata',
    () async {
      for (final breakpoint in [
        null,
        [],
        {'unknownField': 90},
      ]) {
        final api = OfficialAppApi(
          client: MockClient(
            (_) async => jsonResponse({
              'data': {
                'video': videoJson()..['breakpoint'] = breakpoint,
                'anime': animeJson(),
              },
            }),
          ),
        );
        addTearDown(api.dispose);
        final detail = await api.fetchDetail(animeId: '10', videoId: '20');
        expect(detail.episodes.first.id, '20');
      }
    },
  );

  for (final entry in <String, http.Response>{
    'http-302': http.Response(
      '',
      302,
      headers: {'location': 'https://example.test/'},
    ),
    'http-403': http.Response('challenge', 403),
    'not-json': http.Response(
      '<html>verification</html>',
      200,
      headers: {'content-type': 'text/html'},
    ),
    'invalid-json': http.Response(
      '{invalid}',
      200,
      headers: {'content-type': 'application/json'},
    ),
    'invalid-response': jsonResponse({'data': []}),
    'official-rejected': jsonResponse({
      'error': {'message': 'synthetic-private-message'},
    }),
  }.entries) {
    test('reports a fixed error for ${entry.key}', () async {
      final api = OfficialAppApi(client: MockClient((_) async => entry.value));
      addTearDown(api.dispose);
      await expectLater(api.fetchVideo('20'), throwsA(apiError(entry.key)));
    });
  }

  test(
    'rejects oversized chunked responses without waiting for the end',
    () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final api = OfficialAppApi(
        client: _StreamingClient(
          (_) async => http.StreamedResponse(
            stream.stream,
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(api.dispose);
      addTearDown(stream.close);
      final future = api.fetchVideo('20');
      final assertion = expectLater(
        future,
        throwsA(apiError('response-too-large')),
      );
      stream.add(List.filled(OfficialAppApi.maxResponseBytes + 1, 32));
      await assertion;
      expect(cancelled, isTrue);
    },
  );

  test(
    'timeout aborts the HTTP request instead of leaving it pending',
    () async {
      final aborted = Completer<void>();
      final api = OfficialAppApi(
        timeout: const Duration(milliseconds: 20),
        client: _StreamingClient((request) async {
          final trigger = (request as http.Abortable).abortTrigger!;
          await trigger;
          aborted.complete();
          throw http.RequestAbortedException(request.url);
        }),
      );
      addTearDown(api.dispose);
      await expectLater(api.fetchVideo('20'), throwsA(apiError('timeout')));
      await aborted.future;
    },
  );

  test('dispose aborts in-flight requests and rejects new ones', () async {
    final started = Completer<void>();
    final api = OfficialAppApi(
      client: _StreamingClient((request) async {
        started.complete();
        await (request as http.Abortable).abortTrigger!;
        throw http.RequestAbortedException(request.url);
      }),
    );
    addTearDown(api.dispose);
    final assertion = expectLater(
      api.fetchVideo('20'),
      throwsA(apiError('disposed')),
    );
    await started.future;
    api.dispose();
    await assertion;
    await expectLater(api.fetchCatalog(), throwsA(apiError('disposed')));
  });

  test('transport failures do not disclose URLs or payloads', () async {
    final api = OfficialAppApi(
      client: MockClient(
        (_) async => throw http.ClientException('synthetic-private-message'),
      ),
    );
    addTearDown(api.dispose);
    try {
      await api.fetchVideo('20');
      fail('Expected transport failure');
    } on OfficialAppApiException catch (error) {
      expect(error.code, 'network');
      expect(error.toString(), isNot(contains('synthetic-private-message')));
    }
  });

  test(
    'TLS failures stay explicit without exposing certificate text',
    () async {
      final api = OfficialAppApi(
        client: MockClient(
          (_) async =>
              throw const HandshakeException('synthetic-private-message'),
        ),
      );
      addTearDown(api.dispose);
      await expectLater(api.fetchVideo('20'), throwsA(apiError('tls')));
    },
  );

  test(
    'socket diagnostics expose only a numeric operating system code',
    () async {
      final api = OfficialAppApi(
        client: MockClient(
          (_) async => throw const SocketException(
            'synthetic-private-message',
            osError: OSError('synthetic-private-message', 10013),
          ),
        ),
      );
      addTearDown(api.dispose);
      await expectLater(
        api.fetchVideo('20'),
        throwsA(
          apiError(
            'network',
          ).having((error) => error.socketErrorCode, 'socketErrorCode', 10013),
        ),
      );
    },
  );

  test(
    'catalog rotates for transport errors and reuses the same client for 5xx',
    () async {
      var createdClients = 0;
      var closedClients = 0;
      final attempts = <({int client, bool persistent})>[];
      final api = OfficialAppApi(
        retryDelay: Duration.zero,
        clientFactory: () {
          final id = ++createdClients;
          return _TrackingClient(
            onClose: () => closedClients++,
            respond: (request) async {
              attempts.add((
                client: id,
                persistent: request.persistentConnection,
              ));
              if (attempts.length == 1) {
                throw http.ClientException(
                  'Connection closed before full header was received',
                );
              }
              if (attempts.length == 2) {
                return http.StreamedResponse(
                  const Stream<List<int>>.empty(),
                  522,
                );
              }
              final body = utf8.encode(jsonEncode({'data': catalogJson()}));
              return http.StreamedResponse(
                Stream.value(body),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            },
          );
        },
      );
      addTearDown(api.dispose);

      final catalog = await api.fetchCatalog();
      expect(catalog.items.single.id, '10');
      expect(createdClients, 2);
      expect(closedClients, 1);
      expect(attempts, [
        (client: 1, persistent: true),
        (client: 2, persistent: false),
        (client: 2, persistent: false),
      ]);
    },
  );

  test('catalog retries timeout once and does not retry HTTP 403', () async {
    var timeoutAttempts = 0;
    final timeoutApi = OfficialAppApi(
      timeout: const Duration(milliseconds: 20),
      retryDelay: Duration.zero,
      client: _StreamingClient((request) async {
        timeoutAttempts++;
        if (timeoutAttempts == 1) {
          await (request as http.Abortable).abortTrigger!;
          throw http.RequestAbortedException(request.url);
        }
        final body = utf8.encode(jsonEncode({'data': catalogJson()}));
        return http.StreamedResponse(
          Stream.value(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(timeoutApi.dispose);
    final recovered = await timeoutApi.fetchCatalog();
    expect(recovered.items.single.id, '10');
    expect(timeoutAttempts, 2);

    var forbiddenAttempts = 0;
    final forbiddenApi = OfficialAppApi(
      retryDelay: Duration.zero,
      client: MockClient((_) async {
        forbiddenAttempts++;
        return http.Response('blocked', 403);
      }),
    );
    addTearDown(forbiddenApi.dispose);
    await expectLater(
      forbiddenApi.fetchCatalog(),
      throwsA(apiError('http-403')),
    );
    expect(forbiddenAttempts, 1);
  });

  test('dispose cancels pending retry backoff immediately', () async {
    var attempts = 0;
    final firstFailed = Completer<void>();
    final api = OfficialAppApi(
      retryDelay: const Duration(seconds: 30),
      client: MockClient((_) async {
        attempts++;
        if (!firstFailed.isCompleted) firstFailed.complete();
        throw http.ClientException('reset');
      }),
    );
    final pending = api.fetchCatalog();
    await firstFailed.future;
    await Future<void>.delayed(Duration.zero);
    api.dispose();
    await expectLater(pending, throwsA(apiError('disposed')));
    expect(attempts, 1);
  });

  test('request cancellation aborts detail transport', () async {
    final started = Completer<void>();
    final aborted = Completer<void>();
    final cancel = Completer<void>();
    final api = OfficialAppApi(
      client: _StreamingClient((request) async {
        started.complete();
        await (request as http.Abortable).abortTrigger!;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      }),
    );
    addTearDown(api.dispose);
    final assertion = expectLater(
      api.fetchDetail(animeId: '10', videoId: '20', cancel: cancel.future),
      throwsA(apiError('cancelled')),
    );
    await started.future;
    cancel.complete();
    await assertion;
    await aborted.future;
  });

  test(
    '429 Retry-After takes precedence and retains the current client',
    () async {
      var attempts = 0;
      var clients = 0;
      final api = OfficialAppApi(
        retryDelay: const Duration(seconds: 30),
        clientFactory: () {
          clients++;
          return MockClient((_) async {
            if (++attempts == 1) {
              return http.Response('', 429, headers: {'retry-after': '0'});
            }
            return http.Response(
              jsonEncode({'data': catalogJson()}),
              200,
              headers: {'content-type': 'application/json'},
            );
          });
        },
      );
      addTearDown(api.dispose);
      expect(
        (await api.fetchCatalog().timeout(const Duration(seconds: 2))).items,
        isNotEmpty,
      );
      expect(attempts, 2);
      expect(clients, 1);
    },
  );

  test(
    'library pagination maps public results and respects the last page',
    () async {
      final api = OfficialAppApi(
        client: MockClient((request) async {
          expect(request.url.path, '/anime/v1/anime_list.php');
          expect(request.url.queryParameters, {'page': '3'});
          expect(request.headers['cookie'], isNull);
          return http.Response(
            jsonEncode({
              'data': {
                'totalPage': 3,
                'animeList': [
                  {
                    'animeSn': 10,
                    'videoSn': 20,
                    'title': 'Series',
                    'cover': 'https://p2.bahamut.com.tw/cover.jpg',
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.dispose);
      final result = await api.fetchLibraryPage(3);
      expect(result.items.single.id, '10');
      expect(result.hasMore, isFalse);
    },
  );

  test(
    'catalog accepts optional empty popular, numeric volume, normalized times and null sections',
    () {
      final data = catalogJson();
      final seasonal =
          ((data['newAnime'] as Json)['date'] as List).single as Json;
      seasonal['popular'] = '';
      seasonal['volume'] = 8;
      seasonal['upTimeHours'] = '9:30:00';
      data['newAdded'] = null;
      final catalog = OfficialAppMetadata.catalog(
        data,
        now: DateTime.utc(2027, 1, 1),
      );
      final anime = catalog.items.single;
      expect(anime.episodeLabel, '8');
      expect(anime.updateTime, '09:30');
    },
  );
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient({required this.respond, required this.onClose});
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);

  @override
  void close() {
    onClose();
    super.close();
  }
}
