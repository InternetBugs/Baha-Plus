/// Interpolates the presentation clock between native media samples.
///
/// A buffer/volume notification carrying the same media position must not
/// rewind an animation. Small decoder/IPC timing differences are corrected
/// gradually; an actual seek still takes effect immediately.
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
  }) {
    _advance();
    final changed = _lastReported != position;
    final difference = position - _position;
    if (_lastReported == null ||
        !running ||
        (!_running && running) ||
        (changed && difference.abs() > .75)) {
      _position = position;
      _correction = 0;
    } else if (changed) {
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
  int _laneCount = 0;
  double? _lastPosition;
  int get decisionCount => _decisions.length;

  void prepare({required double position, required int laneCount}) {
    if (_laneCount != laneCount ||
        (_lastPosition != null && position < _lastPosition! - .25)) {
      clear();
    }
    _laneCount = laneCount;
    _lastPosition = position;
    _decisions.removeWhere((_, decision) => decision.end <= position);
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
    final occupied = <int>{
      for (final decision in _decisions.values)
        if (decision.mode == mode &&
            decision.lane != null &&
            decision.end > start)
          decision.lane!,
    };
    int? selected;
    for (var lane = 0; lane < _laneCount; lane++) {
      if (!occupied.contains(lane)) {
        selected = lane;
        break;
      }
    }
    // Remember a skipped message too, so it does not suddenly appear halfway
    // across the screen when a lane becomes free in a later frame.
    _decisions[id] = _DanmakuLaneDecision(mode, selected, end);
    return selected;
  }

  void clear() {
    _decisions.clear();
    _lastPosition = null;
  }
}
