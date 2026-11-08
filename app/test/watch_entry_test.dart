import 'package:baha_plus/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Json record() => {
    'anime': {
      'id': '10',
      'title': '測試動畫',
      'cover': 'https://p2.bahamut.com.tw/10.jpg',
      'sections': <String>[],
    },
    'videoId': '20',
    'episodeLabel': '4',
  };

  test('old history snapshots remain readable without new metadata', () {
    final entry = WatchEntry.fromJson(record());
    expect(entry.watchedAt, isNull);
    expect(entry.nextVideoId, isNull);
    expect(entry.videoId, '20');
  });

  test(
    'watch time preserves its instant and next episode preserves its ID',
    () {
      final entry = WatchEntry.fromJson({
        ...record(),
        'watchedAt': '2026-11-08T14:42:00+08:00',
        'nextVideoId': '42',
      });
      expect(entry.watchedAt, DateTime.utc(2026, 11, 8, 6, 42));
      expect(entry.nextVideoId, '42');
    },
  );

  test('invalid or self-referencing next episode IDs are rejected', () {
    for (final id in ['0', '-1', '20', '21.5', '99999999999', 'bad']) {
      expect(
        () => WatchEntry.fromJson({...record(), 'nextVideoId': id}),
        throwsFormatException,
      );
    }
  });

  test('watch time must be a timestamp with an explicit time zone', () {
    for (final time in ['invalid', '2026-11-08', '2026-11-08T14:42:00']) {
      expect(
        () => WatchEntry.fromJson({...record(), 'watchedAt': time}),
        throwsFormatException,
      );
    }
  });
}
