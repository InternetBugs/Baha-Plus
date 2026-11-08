import 'package:baha_plus/core/danmaku_animation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'duplicate player notifications do not rewind the presentation clock',
    () {
      var time = Duration.zero;
      final clock = DanmakuAnimationClock(now: () => time);
      clock.update(position: 10, rate: 1, running: true);
      time = const Duration(milliseconds: 100);
      expect(clock.position, closeTo(10.1, .00001));
      clock.update(position: 10, rate: 1, running: true);
      time = const Duration(milliseconds: 200);
      expect(clock.position, closeTo(10.2, .00001));
      clock.update(position: 10, rate: 1, running: true);
      time = const Duration(milliseconds: 300);
      expect(clock.position, closeTo(10.3, .00001));
    },
  );

  test(
    'coarse native positions remain smooth and monotonic between samples',
    () {
      var time = Duration.zero;
      final clock = DanmakuAnimationClock(now: () => time);
      clock.update(position: 0, rate: 1, running: true);
      var previous = 0.0;
      for (var frame = 1; frame <= 600; frame++) {
        time = Duration(microseconds: frame * 16667);
        if (frame % 5 == 0) {
          final reported = (time.inMilliseconds ~/ 250) * .25;
          clock.update(position: reported, rate: 1, running: true);
        }
        final current = clock.position;
        expect(current, greaterThan(previous));
        expect(current - previous, lessThan(.019));
        previous = current;
      }
      expect(previous, closeTo(10, .1));
    },
  );

  test(
    'pause does not advance in the background and a real seek is immediate',
    () {
      var time = Duration.zero;
      final clock = DanmakuAnimationClock(now: () => time);
      clock.update(position: 20, rate: 1.5, running: true);
      time = const Duration(seconds: 1);
      expect(clock.position, 21.5);
      clock.update(position: 21.5, rate: 1.5, running: false);
      time = const Duration(minutes: 15);
      expect(clock.position, 21.5);
      clock.update(position: 21.5, rate: 1.5, running: true);
      time += const Duration(seconds: 1);
      expect(clock.position, 23);
      clock.update(position: 100, rate: 1.5, running: true);
      expect(clock.position, 100);
    },
  );

  test(
    'an older message leaving does not move surviving messages to another lane',
    () {
      final lanes = StableDanmakuLanes();
      lanes.prepare(position: 1, laneCount: 2);
      expect(lanes.assign(id: 'a', mode: 'rolling', start: 0, end: 10), 0);
      expect(lanes.assign(id: 'b', mode: 'rolling', start: 1, end: 11), 1);
      lanes.prepare(position: 10.1, laneCount: 2);
      expect(lanes.assign(id: 'b', mode: 'rolling', start: 1, end: 11), 1);
      expect(lanes.assign(id: 'c', mode: 'rolling', start: 10.1, end: 20.1), 0);
    },
  );

  test('messages skipped for density cannot pop into a newly freed lane', () {
    final lanes = StableDanmakuLanes();
    lanes.prepare(position: 1, laneCount: 1);
    expect(lanes.assign(id: 'a', mode: 'rolling', start: 0, end: 10), 0);
    expect(lanes.assign(id: 'b', mode: 'rolling', start: 1, end: 11), isNull);
    lanes.prepare(position: 10.1, laneCount: 1);
    expect(lanes.assign(id: 'b', mode: 'rolling', start: 1, end: 11), isNull);
    expect(lanes.assign(id: 'c', mode: 'rolling', start: 10.1, end: 20.1), 0);
    lanes.prepare(position: 31, laneCount: 1);
    expect(lanes.decisionCount, 0);
  });

  test(
    'seeking backwards and changing the viewport release old lane decisions',
    () {
      final lanes = StableDanmakuLanes();
      lanes.prepare(position: 100, laneCount: 3);
      lanes.assign(id: 'a', mode: 'top', start: 99, end: 104);
      lanes.prepare(position: 10, laneCount: 3);
      expect(lanes.decisionCount, 0);
      lanes.assign(id: 'b', mode: 'top', start: 10, end: 15);
      lanes.prepare(position: 11, laneCount: 2);
      expect(lanes.decisionCount, 0);
    },
  );
}
