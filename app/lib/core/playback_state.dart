import 'models.dart';

enum PlaybackPhase {
  loading,
  content,
  advertisement,
  age,
  verification,
  official,
  error,
}

class PlaybackState {
  const PlaybackState({
    this.phase = PlaybackPhase.loading,
    this.surfaceReady = false,
    this.paused = true,
    this.buffering = true,
    this.ended = false,
    this.muted = false,
    this.position = 0,
    this.duration = 0,
    this.buffered = 0,
    this.rate = 1,
    this.qualities = const [],
    this.quality = 0,
    this.hasDanmaku = false,
    this.danmaku = false,
  });

  factory PlaybackState.fromJson(Json body) {
    double number(String key, double max) {
      final value = (body[key] as num).toDouble();
      if (!value.isFinite || value < 0 || value > max) {
        throw FormatException('Invalid playback $key');
      }
      return value;
    }

    final value = PlaybackState(
      phase: PlaybackPhase.values.byName(body['phase'] as String),
      surfaceReady: body['surfaceReady'] as bool,
      paused: body['paused'] as bool,
      buffering: body['buffering'] as bool,
      ended: body['ended'] as bool,
      muted: body['muted'] as bool,
      position: number('position', 172800),
      duration: number('duration', 172800),
      buffered: number('buffered', 172800),
      rate: number('rate', 4),
      qualities: (body['qualities'] as List? ?? const []).cast<int>(),
      quality: body['quality'] as int? ?? 0,
      hasDanmaku: body['hasDanmaku'] as bool? ?? false,
      danmaku: body['danmaku'] as bool? ?? false,
    );
    if (value.rate < .25 ||
        value.position > value.duration + 1 ||
        value.buffered > value.duration + 1 ||
        value.qualities.length > 20 ||
        value.qualities.toSet().length != value.qualities.length ||
        value.qualities.any((height) => height < 144 || height > 4320) ||
        (value.quality != 0 && !value.qualities.contains(value.quality))) {
      throw const FormatException('Invalid playback timeline');
    }
    return value;
  }

  final PlaybackPhase phase;
  final bool surfaceReady, paused, buffering, ended, muted;
  final double position, duration, buffered, rate;
  final List<int> qualities;
  final int quality;
  final bool hasDanmaku, danmaku;
  bool get canOperate =>
      surfaceReady &&
      duration > 0 &&
      (phase == PlaybackPhase.content || phase == PlaybackPhase.advertisement);
  bool get canControl =>
      phase == PlaybackPhase.content && surfaceReady && duration > 0;
}
