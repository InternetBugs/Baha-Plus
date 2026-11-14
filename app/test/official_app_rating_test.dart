import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/official_app_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'official_app_api_test.dart'
    show animeJson, apiError, jsonResponse, videoJson;

Json ratingJson({num? average = 4.8, int count = 649, Json? chart}) => {
  'avg': average,
  'count': count,
  'star_chart': chart ?? {'5': 563, '1': 7, '4': 55, '2': 4, '3': 20},
};

Json detailJson({dynamic fanId = 67798}) => {
  'data': {
    'video': videoJson(),
    'anime': animeJson()
      ..['fanId'] = fanId
      ..['acgSn'] = 148486,
  },
};

void main() {
  test(
    'reads official star statistics anonymously in ascending star order',
    () async {
      final api = OfficialAppApi(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.origin, 'https://api.gamer.com.tw');
          expect(request.url.path, '/acg/v1/reviews_list.php');
          expect(request.url.queryParameters, {'sn': '67798', 't': '4'});
          expect(request.headers['Accept'], 'application/json');
          expect(request.headers.containsKey('cookie'), isFalse);
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(request.followRedirects, isFalse);
          expect(request.body, isEmpty);
          return jsonResponse({
            'data': {
              'rating': ratingJson(),
              'list': [
                {'content': 'review content is not used'},
              ],
            },
          });
        }),
      );
      addTearDown(api.dispose);
      final rating = await api.fetchRating('67798');
      expect(rating.value, 4.8);
      expect(rating.count, 649);
      expect(rating.distribution, [7, 4, 20, 55, 563]);
    },
  );

  test(
    'detail restores its rating using fanId and removes the duplicate metadata score',
    () async {
      final requests = <Uri>[];
      final api = OfficialAppApi(
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.path.endsWith('video.php')) {
            return jsonResponse(detailJson());
          }
          expect(request.url.queryParameters, {'sn': '67798', 't': '4'});
          return jsonResponse({
            'data': {'rating': ratingJson()},
          });
        }),
      );
      addTearDown(api.dispose);
      final detail = await api.fetchDetail(animeId: '10', videoId: '20');
      expect(requests.length, 2);
      expect(detail.rating!.value, 4.8);
      expect(detail.rating!.count, 649);
      expect(detail.rating!.distribution, [7, 4, 20, 55, 563]);
      expect(detail.metadata.any((field) => field.label == '評分'), isFalse);
      expect(detail.episodes.map((episode) => episode.id), ['20', '21', '22']);
    },
  );

  test(
    'missing or invalid fanIds leave the available score and episodes intact',
    () async {
      for (final fanId in [
        null,
        0,
        -1,
        '0',
        '../1',
        '12345678901',
        <String, dynamic>{},
      ]) {
        var requests = 0;
        final api = OfficialAppApi(
          client: MockClient((request) async {
            requests++;
            return jsonResponse(detailJson(fanId: fanId));
          }),
        );
        addTearDown(api.dispose);
        final detail = await api.fetchDetail(animeId: '10', videoId: '20');
        expect(requests, 1);
        expect(detail.rating, isNull);
        expect(
          detail.metadata.any((field) => field.value == '4.3 / 5'),
          isTrue,
        );
        expect(detail.episodes.length, 3);
      }
    },
  );

  test(
    'unavailable or malformed review statistics do not break usable details',
    () async {
      for (final response in [
        http.Response('', 503),
        http.Response('', 302, headers: {'location': 'https://example.test/'}),
        http.Response(
          '<html>verification</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
        jsonResponse({
          'data': {'rating': ratingJson(count: 650)},
        }),
      ]) {
        final api = OfficialAppApi(
          client: MockClient(
            (request) async => request.url.path.endsWith('video.php')
                ? jsonResponse(detailJson())
                : response,
          ),
        );
        addTearDown(api.dispose);
        final detail = await api.fetchDetail(animeId: '10', videoId: '20');
        expect(detail.rating, isNull);
        expect(
          detail.metadata.any((field) => field.value == '4.3 / 5'),
          isTrue,
        );
        expect(detail.episodes.length, 3);
      }
    },
  );

  test(
    'zero ratings accept a null or zero average and an empty distribution',
    () async {
      for (final average in [null, 0]) {
        final api = OfficialAppApi(
          client: MockClient(
            (_) async => jsonResponse({
              'data': {
                'rating': ratingJson(
                  average: average,
                  count: 0,
                  chart: {for (var star = 1; star <= 5; star++) '$star': 0},
                ),
              },
            }),
          ),
        );
        addTearDown(api.dispose);
        final rating = await api.fetchRating('67798');
        expect(rating.value, 0);
        expect(rating.count, 0);
        expect(rating.distribution, [0, 0, 0, 0, 0]);
      }
    },
  );

  test(
    'rejects invalid averages, counts and inconsistent star charts',
    () async {
      for (final rating in [
        ratingJson()..['avg'] = 5.1,
        ratingJson()..['avg'] = '4.8',
        ratingJson()..['avg'] = null,
        ratingJson()..['count'] = -1,
        ratingJson()..['count'] = 649.5,
        ratingJson()..['count'] = '649',
        ratingJson()..['count'] = 100000001,
        ratingJson(count: 650),
        ratingJson(chart: {'1': -7, '2': 4, '3': 20, '4': 55, '5': 577}),
        ratingJson(chart: {'1': 7.5, '2': 4, '3': 20, '4': 55, '5': 563}),
        ratingJson(chart: {'1': '7', '2': 4, '3': 20, '4': 55, '5': 563}),
        ratingJson(chart: {'1': 7, '2': 4, '3': 20, '4': 55}),
        ratingJson(chart: {'1': 7, '2': 4, '3': 20, '4': 55, '5': 563, '6': 0}),
      ]) {
        final api = OfficialAppApi(
          client: MockClient(
            (_) async => jsonResponse({
              'data': {'rating': rating},
            }),
          ),
        );
        addTearDown(api.dispose);
        await expectLater(
          api.fetchRating('67798'),
          throwsA(apiError('invalid-rating')),
        );
      }
    },
  );

  test('rejects invalid fanIds before requesting a review endpoint', () async {
    var requested = false;
    final api = OfficialAppApi(
      client: MockClient((_) async {
        requested = true;
        return jsonResponse({});
      }),
    );
    addTearDown(api.dispose);
    for (final fanId in ['0', '-1', '../1', '67798&t=1', '12345678901']) {
      await expectLater(
        api.fetchRating(fanId),
        throwsA(apiError('invalid-video-id')),
      );
    }
    expect(requested, isFalse);
  });
}
