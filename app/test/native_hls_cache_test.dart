import 'dart:async';
import 'dart:io';

import 'package:baha_plus/data/native_hls_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final master = Uri.parse('https://bahamut.akamaized.net/show/master.m3u8');

const media = '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
first.ts?token=private
#EXTINF:10,
second.ts
#EXTINF:10,
third.ts
#EXT-X-ENDLIST
''';

List<Uri> mediaUris(String playlist) => playlist
    .split('\n')
    .where((line) => line.isNotEmpty && !line.startsWith('#'))
    .map(Uri.parse)
    .toList();

Uri attributeUri(String playlist, String tag) => Uri.parse(
  RegExp(r'URI="([^"]+)"').firstMatch(
    playlist.split('\n').firstWhere((line) => line.startsWith(tag)),
  )![1]!,
);

void main() {
  late Directory directory;
  late NativeHlsCache cache;
  late http.Client local;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handle;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('baha-cache-test-');
    local = http.Client();
    requests = [];
    handle = (request) async => http.Response(
      request.url.path.endsWith('.m3u8') ? media : 'segment-data',
      200,
    );
    cache = NativeHlsCache(
      headers: const {
        'Origin': 'https://ani.gamer.com.tw',
        'Referer': 'https://ani.gamer.com.tw/animeVideo.php',
        'User-Agent': 'test-device',
      },
      client: MockClient((request) {
        requests.add(request);
        return handle(request);
      }),
      createDirectory: () async => directory,
    );
    await cache.start();
  });

  tearDown(() async {
    local.close();
    await cache.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'completed segments survive repeated player requests without CDN traffic',
    () async {
      final root = cache.playlist(master);
      final playlist = await local.read(root);
      final parts = mediaUris(playlist);
      expect(parts, hasLength(3));
      expect(playlist, isNot(contains('bahamut.akamaized.net')));
      expect(playlist, isNot(contains('private')));
      expect(cache.bufferedRanges(master), isEmpty);
      expect(await local.read(parts[0]), 'segment-data');
      expect(await local.read(parts[2]), 'segment-data');
      expect(cache.bufferedRanges(master), [
        (start: 0.0, end: 10.0),
        (start: 20.0, end: 30.0),
      ]);
      final downloaded = cache.downloadedBytes;
      final count = requests.length;
      handle = (_) async => throw const SocketException('network offline');
      expect(await local.read(root), playlist);
      expect(await local.read(parts[0]), 'segment-data');
      expect(await local.read(parts[2]), 'segment-data');
      expect(requests, hasLength(count));
      expect(cache.downloadedBytes, downloaded);
      expect(requests.first.headers['Origin'], 'https://ani.gamer.com.tw');
      expect(requests[1].url.query, 'token=private');
      expect(requests.every((request) => !request.followRedirects), isTrue);
      expect(
        requests.every((request) => !request.headers.containsKey('cookie')),
        isTrue,
      );
    },
  );

  test('concurrent requests share one complete transfer', () async {
    final parts = mediaUris(await local.read(cache.playlist(master)));
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    handle = (_) {
      started.complete();
      return pending.future;
    };
    final first = local.read(parts.first);
    await started.future;
    final second = local.read(parts.first);
    pending.complete(http.Response('shared-segment', 200));
    expect(await Future.wait([first, second]), [
      'shared-segment',
      'shared-segment',
    ]);
    expect(requests, hasLength(2));
  });

  test(
    'failed transfers are never advertised as cached and can retry',
    () async {
      final parts = mediaUris(await local.read(cache.playlist(master)));
      handle = (_) async => http.Response('unavailable', 503);
      expect((await local.get(parts.first)).statusCode, 502);
      expect(cache.bufferedRanges(master), isEmpty);
      handle = (_) async => http.Response('complete', 200);
      expect(await local.read(parts.first), 'complete');
      expect(cache.bufferedRanges(master), [(start: 0.0, end: 10.0)]);
    },
  );

  test(
    'a truncated segment is discarded before a later complete retry',
    () async {
      await cache.close();
      directory = await Directory.systemTemp.createTemp('baha-cache-test-');
      var truncated = true;
      cache = NativeHlsCache(
        headers: const {},
        createDirectory: () async => directory,
        client: MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('.m3u8')) {
            return http.StreamedResponse(Stream.value(media.codeUnits), 200);
          }
          return http.StreamedResponse(
            Stream.value(truncated ? [1, 2] : [1, 2, 3, 4]),
            200,
            contentLength: 4,
          );
        }),
      );
      await cache.start();
      final part = mediaUris(await local.read(cache.playlist(master))).first;
      expect((await local.get(part)).statusCode, 502);
      expect(cache.bufferedRanges(master), isEmpty);
      expect(await directory.list().isEmpty, isTrue);
      truncated = false;
      expect((await local.get(part)).bodyBytes, [1, 2, 3, 4]);
      expect(cache.bufferedRanges(master), [(start: 0.0, end: 10.0)]);
    },
  );

  test('local byte ranges and HEAD reuse the same completed segment', () async {
    final part = mediaUris(await local.read(cache.playlist(master))).first;
    final partial = await local.get(part, headers: {'Range': 'bytes=2-5'});
    expect(partial.statusCode, 206);
    expect(partial.body, 'gmen');
    expect(partial.headers['content-range'], 'bytes 2-5/12');
    final suffix = await local.get(part, headers: {'Range': 'bytes=-4'});
    expect(suffix.body, 'data');
    final head = await local.head(part);
    expect(head.statusCode, 200);
    expect(head.body, isEmpty);
    expect(head.headers['content-length'], '12');
    for (final range in ['bytes=999-', 'bytes=4-1', 'bytes=-0', 'bytes=a-b']) {
      final response = await local.get(part, headers: {'Range': range});
      expect(response.statusCode, 416);
      expect(response.headers['content-range'], 'bytes */12');
    }
    expect(requests, hasLength(2));
  });

  test(
    'keys and initialization data gate cached ranges and keys stay in memory',
    () async {
      handle = (request) async => http.Response(
        request.url.path.endsWith('.m3u8')
            ? '''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXT-X-MAP:URI="init.mp4"
#EXTINF:10,
first.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:10,
second.ts
#EXT-X-ENDLIST
'''
            : request.url.path.endsWith('key.bin')
            ? 'private-key'
            : 'encrypted-media',
        200,
      );
      final playlist = await local.read(cache.playlist(master));
      final parts = mediaUris(playlist);
      await local.read(parts[0]);
      expect(cache.bufferedRanges(master), isEmpty);
      final key = attributeUri(playlist, '#EXT-X-KEY:');
      await local.read(key);
      expect(cache.bufferedRanges(master), isEmpty);
      await local.read(attributeUri(playlist, '#EXT-X-MAP:'));
      expect(cache.bufferedRanges(master), [(start: 0.0, end: 10.0)]);
      await local.read(parts[1]);
      expect(cache.bufferedRanges(master), [(start: 0.0, end: 20.0)]);
      final files = await directory
          .list()
          .where((file) => file is File)
          .toList();
      expect(files, hasLength(3));
      for (final file in files.cast<File>()) {
        expect(await file.readAsString(), isNot(contains('private-key')));
      }
      final count = requests.length;
      expect(await local.read(key), 'private-key');
      expect(requests, hasLength(count));
    },
  );

  test(
    'HLS byte ranges become distinct cached objects with correct offsets',
    () async {
      handle = (request) async {
        if (request.url.path.endsWith('.m3u8')) {
          return http.Response('''#EXTM3U
#EXT-X-MAP:URI="combined.mp4",BYTERANGE="4@0"
#EXTINF:10,
#EXT-X-BYTERANGE:4@4
combined.mp4
#EXTINF:10,
#EXT-X-BYTERANGE:4
combined.mp4
#EXT-X-ENDLIST
''', 200);
        }
        final range = request.headers['Range']!;
        final start = int.parse(RegExp(r'\d+').firstMatch(range)![0]!);
        return http.Response(
          'abcdefghijkl'.substring(start, start + 4),
          206,
          headers: {'content-range': 'bytes $start-${start + 3}/12'},
        );
      };
      final playlist = await local.read(cache.playlist(master));
      expect(playlist, isNot(contains('BYTERANGE')));
      final parts = mediaUris(playlist);
      expect(parts[0], isNot(parts[1]));
      expect(await local.read(parts[0]), 'efgh');
      expect(await local.read(parts[1]), 'ijkl');
      expect(cache.bufferedRanges(master), isEmpty);
      expect(await local.read(attributeUri(playlist, '#EXT-X-MAP:')), 'abcd');
      expect(cache.bufferedRanges(master), [(start: 0.0, end: 20.0)]);
      expect(requests.skip(1).map((request) => request.headers['Range']), [
        'bytes=4-7',
        'bytes=8-11',
        'bytes=0-3',
      ]);
      expect(await local.read(parts[0]), 'efgh');
      expect(requests, hasLength(4));
    },
  );

  test(
    'master playlists select cached ranges from the requested quality',
    () async {
      handle = (request) async => http.Response(
        request.url.path.endsWith('master.m3u8')
            ? '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000
360/media.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000
1080/media.m3u8
'''
            : request.url.path.endsWith('.m3u8')
            ? media
            : 'segment',
        200,
      );
      final variants = mediaUris(await local.read(cache.playlist(master)));
      final low = mediaUris(await local.read(variants[0]));
      await local.read(low[0]);
      expect(cache.bufferedRanges(master), [(start: 0.0, end: 10.0)]);
      final high = mediaUris(await local.read(variants[1]));
      expect(cache.bufferedRanges(master), isEmpty);
      await local.read(high[2]);
      expect(cache.bufferedRanges(master), [(start: 20.0, end: 30.0)]);
      await local.read(variants[0]);
      expect(cache.bufferedRanges(master), [(start: 0.0, end: 10.0)]);
    },
  );

  test('eviction removes real cached ranges while keeping seek gaps', () async {
    await cache.close();
    directory = await Directory.systemTemp.createTemp('baha-cache-test-');
    cache = NativeHlsCache(
      headers: const {},
      maxBytes: 8,
      client: MockClient(
        (request) async => http.Response(
          request.url.path.endsWith('.m3u8') ? media : 'data',
          200,
        ),
      ),
      createDirectory: () async => directory,
    );
    await cache.start();
    final parts = mediaUris(await local.read(cache.playlist(master)));
    await local.read(parts[0]);
    await local.read(parts[1]);
    await local.read(parts[0]); // Keep the first segment most recently used.
    await local.read(parts[2]);
    expect(cache.bufferedRanges(master), [
      (start: 0.0, end: 10.0),
      (start: 20.0, end: 30.0),
    ]);
    expect(await directory.list().length, 2);
  });

  test(
    'a purged temporary file is downloaded again instead of served as empty',
    () async {
      final part = mediaUris(await local.read(cache.playlist(master))).first;
      await local.read(part);
      await for (final file in directory.list()) {
        await file.delete();
      }
      expect(await local.read(part), 'segment-data');
      expect(requests, hasLength(3));
    },
  );

  test(
    'only registered local resources and authorized CDN URLs are accepted',
    () async {
      final root = cache.playlist(master);
      for (final path in [
        '/wrong-token/0.m3u8',
        '${root.path}?url=https://other.invalid/private',
        '${root.pathSegments.first}/999.bin',
        '/${root.pathSegments.first}/999.bin',
      ]) {
        expect((await local.get(root.resolve(path))).statusCode, 404);
      }
      expect((await local.post(root)).statusCode, 405);
      expect(requests, isEmpty);
      for (final uri in [
        'http://bahamut.akamaized.net/master.m3u8',
        'https://other.invalid/master.m3u8',
        'https://user@bahamut.akamaized.net/master.m3u8',
        'https://bahamut.akamaized.net:444/master.m3u8',
      ]) {
        expect(() => cache.playlist(Uri.parse(uri)), throwsFormatException);
      }
      handle = (_) async => http.Response('''#EXTM3U
#EXTINF:10,
https://other.invalid/private.ts
#EXT-X-ENDLIST
''', 200);
      expect((await local.get(root)).statusCode, 502);
      expect(requests, hasLength(1));
    },
  );

  test(
    'redirects and malformed or incomplete playlists fail without caching',
    () async {
      final root = cache.playlist(master);
      for (final body in [
        'not a playlist',
        '#EXTM3U\n#EXTINF:NaN,\nfirst.ts\n#EXT-X-ENDLIST',
        '#EXTM3U\n#EXTINF:10,\nfirst.ts',
        '#EXTM3U\n#EXTINF:10,\n#EXT-X-BYTERANGE:4\nfirst.ts\n#EXT-X-ENDLIST',
      ]) {
        handle = (_) async => http.Response(body, 200);
        expect((await local.get(root)).statusCode, 502);
        expect(cache.bufferedRanges(master), isEmpty);
      }
      handle = (_) async => http.Response(
        '',
        302,
        headers: {'location': 'https://other.invalid/private'},
      );
      expect((await local.get(root)).statusCode, 502);
      expect(requests.every((request) => request.url == master), isTrue);
    },
  );

  test('different episodes cannot share another session cache URL', () async {
    final oldRoot = cache.playlist(master);
    final oldPart = mediaUris(await local.read(oldRoot)).first;
    await local.read(oldPart);
    await cache.close();
    directory = await Directory.systemTemp.createTemp('baha-cache-test-');
    cache = NativeHlsCache(
      headers: const {},
      createDirectory: () async => directory,
      client: MockClient((_) async => http.Response('another-episode', 200)),
    );
    await cache.start();
    final next = cache.playlist(master.resolve('another.m3u8'));
    expect((await local.get(next.replace(path: oldPart.path))).statusCode, 404);
    expect(cache.bufferedRanges(master), isEmpty);
  });

  test(
    'closing removes media files, closes the port and invalidates old URLs',
    () async {
      final root = cache.playlist(master);
      final part = mediaUris(await local.read(root)).first;
      await local.read(part);
      expect(await directory.exists(), isTrue);
      await cache.close();
      expect(await directory.exists(), isFalse);
      expect(cache.bufferedRanges(master), isEmpty);
      await expectLater(local.get(part), throwsA(isA<http.ClientException>()));
      await cache.close();
    },
  );
}
