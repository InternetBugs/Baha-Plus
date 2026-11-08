import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import '../core/models.dart';
import '../core/playback_state.dart';

class NativePlaybackSource {
  NativePlaybackSource.fromJson(Json json)
    : master = mediaUri(json['master']),
      variants = parseVariants(json['variants']),
      position = (json['position'] as num).toDouble(),
      duration = (json['duration'] as num).toDouble(),
      rate = (json['rate'] as num).toDouble(),
      paused = json['paused'] as bool,
      muted = json['muted'] as bool {
    if (variants.length > 20 ||
        variants.keys.any((height) => height < 144 || height > 4320) ||
        !position.isFinite ||
        !duration.isFinite ||
        position < 0 ||
        duration <= 0 ||
        duration > 172800 ||
        position > duration + 1 ||
        !const [.5, .75, 1, 1.25, 1.5, 1.75, 2].contains(rate)) {
      throw const FormatException('Invalid native playback source');
    }
  }

  final Uri master;
  final Map<int, Uri> variants;
  final double position, duration, rate;
  final bool paused, muted;

  static Map<int, Uri> parseVariants(dynamic raw) {
    if (raw is! List || raw.length > 20) {
      throw const FormatException('Invalid native variant list');
    }
    final result = <int, Uri>{};
    for (final item in raw) {
      if (item is! Json || item['height'] is! int) {
        throw const FormatException('Invalid native variant');
      }
      final height = item['height'] as int;
      if (height < 144 || height > 4320 || result.containsKey(height)) {
        throw const FormatException('Invalid native variant height');
      }
      result[height] = mediaUri(item['url']);
    }
    return Map.unmodifiable(result);
  }

  static Uri mediaUri(dynamic raw) {
    if (raw is! String || raw.length > 4096) {
      throw const FormatException('Invalid media URL');
    }
    final uri = Uri.parse(raw);
    if (uri.scheme != 'https' ||
        uri.host != 'bahamut.akamaized.net' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443) ||
        !uri.path.toLowerCase().endsWith('.m3u8')) {
      throw const FormatException('Invalid media origin');
    }
    return uri;
  }
}

/// Android owns the video texture and actual media clock. The official portal
/// receives numeric state only; media URLs never enter logs or preferences.
class NativePlayback extends ChangeNotifier {
  NativePlayback({
    required this.document,
    required this.source,
    required this.userAgent,
    required this.onState,
  });

  final String document, userAgent;
  final NativePlaybackSource source;
  final void Function(PlaybackState) onState;
  VideoPlayerController? video;
  Timer? _clock;
  bool _disposed = false, _active = false, _polling = false, _blocked = false;
  bool _foreground = true;
  int _pauseVersion = 0;
  int _generation = 0, _quality = 0;
  double _position = 0;
  Future<bool> _commands = Future.value(true);

  bool get active => _active && !_disposed;
  int get quality => _quality;
  PlaybackState get state {
    final value = video?.value;
    final duration = value?.isInitialized == true
        ? value!.duration.inMilliseconds / 1000
        : source.duration;
    var buffered = 0.0;
    for (final range in value?.buffered ?? const <DurationRange>[]) {
      final end = range.end.inMilliseconds / 1000;
      if (end > buffered) buffered = end;
    }
    return PlaybackState(
      phase: _blocked || value?.hasError == true
          ? PlaybackPhase.error
          : value?.isInitialized == true
          ? PlaybackPhase.content
          : PlaybackPhase.loading,
      surfaceReady: value?.isInitialized == true,
      paused: value?.isPlaying != true,
      buffering: value?.isInitialized != true || value?.isBuffering == true,
      ended: value?.isCompleted == true,
      muted: value?.volume == 0,
      position: _position.clamp(0, duration),
      duration: duration,
      buffered: buffered.clamp(0, duration),
      rate: value?.playbackSpeed ?? source.rate,
      qualities: source.variants.keys.toList()..sort((a, b) => b.compareTo(a)),
      quality: _quality,
      hasDanmaku: true,
      danmaku: true,
    );
  }

  Json get clock => {
    'position': state.position,
    'duration': state.duration,
    'buffered': state.buffered,
    'paused': state.paused,
    'rate': state.rate,
    'muted': state.muted,
    'ended': state.ended,
    'seeking': false,
    'videoWidth': video?.value.size.width.round() ?? 0,
    'videoHeight': video?.value.size.height.round() ?? 0,
  };

  Future<void> initialize(int preferredQuality) async {
    _quality = source.variants.containsKey(preferredQuality)
        ? preferredQuality
        : 0;
    _position = source.position;
    if (!await _load(_quality, initial: true)) {
      throw StateError('Native media initialization failed');
    }
  }

  Future<bool> _load(int quality, {bool initial = false}) async {
    final generation = ++_generation;
    final pauseVersion = _pauseVersion;
    final previous = video;
    final old = state;
    await previous?.pause();
    final next = VideoPlayerController.networkUrl(
      quality == 0 ? source.master : source.variants[quality]!,
      formatHint: VideoFormat.hls,
      httpHeaders: {
        'Origin': 'https://ani.gamer.com.tw',
        'Referer': 'https://ani.gamer.com.tw/animeVideo.php',
        'User-Agent': userAgent,
      },
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    try {
      await next.initialize().timeout(const Duration(seconds: 25));
      if (_disposed || generation != _generation) {
        await next.dispose();
        return false;
      }
      final position = initial ? source.position : old.position;
      await next.seekTo(Duration(milliseconds: (position * 1000).round()));
      await next.setPlaybackSpeed(initial ? source.rate : old.rate);
      await next.setVolume((initial ? source.muted : old.muted) ? 0 : 1);
      if (_disposed || generation != _generation) {
        await next.dispose();
        return false;
      }
      previous?.removeListener(_changed);
      video = next;
      _position = position;
      _quality = quality;
      next.addListener(_changed);
      notifyListeners();
      await previous?.dispose();
      if (_active &&
          _foreground &&
          pauseVersion == _pauseVersion &&
          !old.paused) {
        await next.play();
      }
      _changed();
      return true;
    } catch (_) {
      await next.dispose();
      if (!_disposed && generation == _generation && previous != null) {
        if (_active &&
            _foreground &&
            pauseVersion == _pauseVersion &&
            !old.paused) {
          await previous.play();
        }
      }
      return false;
    }
  }

  Future<void> activate({
    required bool applicationActive,
    required Json timeline,
  }) async {
    if (_disposed) return;
    _foreground = applicationActive;
    final position = (timeline['position'] as num).toDouble();
    _position = position.clamp(0, state.duration);
    await video?.seekTo(Duration(milliseconds: (_position * 1000).round()));
    await video?.setPlaybackSpeed((timeline['rate'] as num).toDouble());
    await video?.setVolume(timeline['muted'] == true ? 0 : 1);
    if (_disposed) return;
    _active = true;
    _clock = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_samplePosition()),
    );
    if (timeline['paused'] == false && applicationActive) await video?.play();
    _changed();
  }

  Future<void> _samplePosition() async {
    if (_disposed || !_active || _polling || video == null) return;
    _polling = true;
    final current = video;
    try {
      final position = await current!.position;
      if (!_disposed && current == video && position != null) {
        _position = position.inMilliseconds / 1000;
        _changed();
      }
    } catch (_) {
      // The next event/poll will carry the state after a source replacement.
    } finally {
      _polling = false;
    }
  }

  void _changed() {
    if (_disposed) return;
    if (active) onState(state);
    notifyListeners();
  }

  Future<bool> command(String action, double? value) {
    final pending = _commands.then((_) => _command(action, value));
    _commands = pending.catchError((_) => false);
    return pending;
  }

  Future<bool> _command(String action, double? value) async {
    final current = video;
    if (!active ||
        _blocked ||
        current == null ||
        !current.value.isInitialized) {
      return false;
    }
    switch (action) {
      case 'play':
        if (!_foreground) return false;
        await current.play();
      case 'pause':
        await current.pause();
      case 'seek':
        if (value == null || !value.isFinite) return false;
        _position = value.clamp(0, state.duration);
        await current.seekTo(
          Duration(milliseconds: (_position * 1000).round()),
        );
      case 'rate':
        if (!const [.5, .75, 1, 1.25, 1.5, 1.75, 2].contains(value)) {
          return false;
        }
        await current.setPlaybackSpeed(value!);
      case 'mute':
        await current.setVolume(current.value.volume == 0 ? 1 : 0);
      case 'quality':
        if (value == null ||
            value != value.roundToDouble() ||
            (value != 0 && !source.variants.containsKey(value.toInt()))) {
          return false;
        }
        if (value.toInt() != _quality && !await _load(value.toInt())) {
          return false;
        }
      default:
        return false;
    }
    await _samplePosition();
    _changed();
    return true;
  }

  Future<void> pause() async {
    _pauseVersion++;
    await video?.pause();
    await _samplePosition();
  }

  Future<void> setApplicationActive(bool value) async {
    _foreground = value;
    if (!value) await pause();
  }

  Future<void> block({bool committed = false}) async {
    if (_disposed || _blocked) return;
    if (committed) _active = true;
    _blocked = true;
    _clock?.cancel();
    try {
      await pause();
    } catch (_) {
      // Even a disconnected platform player must expose the retry surface.
    }
    _changed();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _clock?.cancel();
    final current = video;
    current?.removeListener(_changed);
    video = null;
    if (current != null) unawaited(current.dispose());
    super.dispose();
  }
}
