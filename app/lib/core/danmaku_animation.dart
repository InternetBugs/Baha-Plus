import 'dart:typed_data';

/// Interpolates the presentation clock between native media samples.
///
/// A buffer/volume notification carrying the same media position must not
/// rewind an animation. Small decoder/IPC timing differences are corrected
/// gradually. Pausing freezes the presentation clock even if the notification
/// still carries an older native sample. Explicit seeks use `discontinuity`
/// rather than a distance threshold, including small seeks while paused.
class DanmakuAnimationClock {
  DanmakuAnimationClock({required Duration Function() now}) : _now = now;
  final Duration Function() _now;
  Duration? _lastTick;
  double? _lastReported;
  double _position = 0, _rate = 1, _correction = 0;
  bool _running = false;

  double get position {
    _advance();
    return _position;
  }

  void _advance() {
    final now = _now();
    final before = _lastTick;
    _lastTick = now;
    if (!_running || before == null) return;
    final elapsed = (now - before).inMicroseconds / 1e6;
    if (elapsed <= 0) return;
    final step = elapsed * _rate;
    // At least 90% of the nominal forward movement is retained. Correcting
    // a late native timestamp can never move a rolling message backwards.
    final adjustment = _correction.clamp(-step * .1, step * .1);
    _position += step + adjustment;
    _correction -= adjustment;
  }

  void update({
    required double position,
    required double rate,
    required bool running,
    bool discontinuity = false,
  }) {
    _advance();
    final changed = _lastReported != position;
    final difference = position - _position;
    if (_lastReported == null || discontinuity) {
      _position = position;
      _correction = 0;
    } else if (!running) {
      // Final native position samples may arrive after the paused event.
      // Keep both the horizontal position and existing lane decisions frozen.
      _correction = 0;
    } else if (changed || !_running) {
      _correction = difference;
    }
    _lastReported = position;
    _rate = rate;
    _running = running;
  }
}

class _DanmakuLaneDecision {
  const _DanmakuLaneDecision(this.mode, this.lane, this.end);
  final String mode;
  final int? lane;
  final double end;
}

/// A visible message keeps its assigned lane until it expires. Recomputing
/// all lanes every frame makes surviving messages jump when an older one exits.
class StableDanmakuLanes {
  final _decisions = <String, _DanmakuLaneDecision>{};
  Float64List _rollingEnds = Float64List(0);
  Float64List _topEnds = Float64List(0);
  Float64List _bottomEnds = Float64List(0);
  double _nextExpiry = double.infinity;
  int _laneCount = 0;
  double? _lastPosition;
  int get decisionCount => _decisions.length;

  Float64List _endsForMode(String mode) => switch (mode) {
    'rolling' => _rollingEnds,
    'top' => _topEnds,
    'bottom' => _bottomEnds,
    _ => _rollingEnds,
  };

  void prepare({required double position, required int laneCount}) {
    if (_laneCount != laneCount ||
        (_lastPosition != null && position < _lastPosition! - .25)) {
      clear();
      _laneCount = laneCount;
      _rollingEnds = Float64List(laneCount)
        ..fillRange(0, laneCount, double.negativeInfinity);
      _topEnds = Float64List(laneCount)
        ..fillRange(0, laneCount, double.negativeInfinity);
      _bottomEnds = Float64List(laneCount)
        ..fillRange(0, laneCount, double.negativeInfinity);
    }
    _lastPosition = position;
    if (position >= _nextExpiry) {
      var next = double.infinity;
      List<String>? expired;
      _decisions.forEach((id, decision) {
        if (decision.end <= position) {
          (expired ??= <String>[]).add(id);
        } else if (decision.end < next) {
          next = decision.end;
        }
      });
      if (expired != null) {
        for (var i = 0; i < expired!.length; i++) {
          _decisions.remove(expired![i]);
        }
      }
      _nextExpiry = next;
    }
  }

  int? assign({
    required String id,
    required String mode,
    required double start,
    required double end,
  }) {
    final previous = _decisions[id];
    if (previous != null) return previous.lane;
    if (_decisions.length >= 512) return null;
    final laneEnds = _endsForMode(mode);
    final currentPos = _lastPosition ?? start;
    int? selected;
    for (var lane = 0; lane < _laneCount; lane++) {
      final occupiedUntil = laneEnds[lane];
      if (occupiedUntil <= currentPos || occupiedUntil <= start) {
        selected = lane;
        laneEnds[lane] = end;
        break;
      }
    }
    // Remember a skipped message too, so it does not suddenly appear halfway
    // across the screen when a lane becomes free in a later frame.
    _decisions[id] = _DanmakuLaneDecision(mode, selected, end);
    if (end < _nextExpiry) _nextExpiry = end;
    return selected;
  }

  void clear() {
    _decisions.clear();
    _rollingEnds.fillRange(0, _rollingEnds.length, double.negativeInfinity);
    _topEnds.fillRange(0, _topEnds.length, double.negativeInfinity);
    _bottomEnds.fillRange(0, _bottomEnds.length, double.negativeInfinity);
    _nextExpiry = double.infinity;
    _lastPosition = null;
  }
}
