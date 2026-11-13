import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../core/models.dart';
import '../core/playback_state.dart';
import 'app_diagnostics.dart';
import 'native_download_speed.dart';

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

/// The plugin's timer also calls [position], independently of host sampling.
/// Discard a query if any seek crosses it, including after that seek completes.
class _SeekAwareVideoPlayerController extends VideoPlayerController {
  _SeekAwareVideoPlayerController(
    super.url, {
    required super.httpHeaders,
    required super.videoPlayerOptions,
  }) : super.networkUrl(formatHint: VideoFormat.hls);

  int _seekEpoch = 0, _pendingSeeks = 0;

  @override
  Future<Duration?> get position async {
    if (_pendingSeeks > 0) return null;
    final epoch = _seekEpoch;
    final sampled = await super.position;
    return epoch == _seekEpoch && _pendingSeeks == 0 ? sampled : null;
  }

  @override
  Future<void> seekTo(Duration position) async {
    _seekEpoch++;
    _pendingSeeks++;
    try {
      await super.seekTo(position);
    } finally {
      _pendingSeeks--;
    }
  }
}

/// AVPlayer/ExoPlayer owns the video texture and actual media clock.
/// Media URLs never enter logs or preferences.
class NativePlayback extends ChangeNotifier {
  NativePlayback({
    required this.document,
    required this.source,
    required this.userAgent,
    required this.onState,
    AppDiagnostics? diagnostics,
  }) : diagnostics = diagnostics ?? AppDiagnostics.instance;

  final AppDiagnostics diagnostics;
  final String document, userAgent;
  final NativePlaybackSource source;
  final void Function(PlaybackState) onState;
  late final _downloadSpeed = NativeDownloadSpeed(onSpeed: _downloadChanged);
  double _downloadBytesPerSecond = 0;
  VideoPlayerController? video;
  bool _disposed = false, _active = false, _polling = false, _blocked = false;
  bool _seeking = false;
  bool _foreground = true;
  int _pauseVersion = 0, _seekRevision = 0;
  int _generation = 0, _quality = 0;
  double _position = 0;
  Duration? _lastVideoPosition;
  String? failureStage, failureCode;
  Future<bool> _commands = Future.value(true);
  Future<void> _released = Future.value();

  bool get active => _active && !_disposed;
  int get seekRevision => _seekRevision;
  Future<void> get released => _released;
  int get quality => _quality;
  PlaybackState get state {
    final value = video?.value;
    final duration = value?.isInitialized == true
        ? value!.duration.inMilliseconds / 1000
        : source.duration;
    var buffered = 0.0;
    final bufferedRanges = <PlaybackBufferRange>[];
    for (final range in value?.buffered ?? const <DurationRange>[]) {
      final start = (range.start.inMilliseconds / 1000).clamp(0.0, duration);
      final end = range.end.inMilliseconds / 1000;
      if (end > buffered) buffered = end;
      if (end > start) {
        bufferedRanges.add((start: start, end: end.clamp(0.0, duration)));
      }
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
      bufferedRanges: List.unmodifiable(bufferedRanges),
      downloadBytesPerSecond: _downloadBytesPerSecond,
      rate: value?.playbackSpeed ?? source.rate,
      qualities: source.variants.keys.toList()..sort((a, b) => b.compareTo(a)),
      quality: _quality,
      hasDanmaku: true,
      danmaku: true,
    );
  }

  Future<void> initialize(int preferredQuality) async {
    _downloadSpeed.setEnabled(_foreground);
    unawaited(
      _downloadSpeed.start(document, [
        source.master.toString(),
        ...source.variants.values.map((uri) => uri.toString()),
      ]),
    );
    _quality = source.variants.containsKey(preferredQuality)
        ? preferredQuality
        : 0;
    _position = source.position;
    if (!await _load(_quality, initial: true)) {
      throw StateError('Native media initialization failed');
    }
    _syncDownloadSampling();
  }

  Future<bool> _load(int quality, {bool initial = false}) async {
    final generation = ++_generation;
    final pauseVersion = _pauseVersion;
    final previous = video;
    final old = state;
    var stage = 'pause-previous';
    final elapsed = Stopwatch()..start();
    VideoPlayerController? next;
    try {
      await previous?.pause();
      stage = 'create';
      next = _SeekAwareVideoPlayerController(
        quality == 0 ? source.master : source.variants[quality]!,
        httpHeaders: {
          'Origin': 'https://ani.gamer.com.tw',
          'Referer': 'https://ani.gamer.com.tw/animeVideo.php',
          if (userAgent.isNotEmpty) 'User-Agent': userAgent,
        },
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: false,
          // Our lifecycle guard owns pause intent, including source changes.
          // Disable the plugin observer that otherwise resumes on foreground.
          // This does not enable iOS background audio or add UIBackgroundModes.
          allowBackgroundPlayback: true,
          // PlaybackEnvironment is the sole owner of the app's idle timer.
          preventsDisplaySleepDuringVideoPlayback: false,
        ),
      );
      stage = 'initialize';
      await next.initialize().timeout(const Duration(seconds: 25));
      if (_disposed || generation != _generation) {
        await next.dispose();
        return false;
      }
      final position = initial ? source.position : old.position;
      stage = 'seek';
      await next.seekTo(Duration(milliseconds: (position * 1000).round()));
      stage = 'rate';
      await next.setPlaybackSpeed(initial ? source.rate : old.rate);
      stage = 'volume';
      await next.setVolume((initial ? source.muted : old.muted) ? 0 : 1);
      if (_disposed || generation != _generation) {
        await next.dispose();
        return false;
      }
      previous?.removeListener(_changed);
      video = next;
      _position = position;
      _lastVideoPosition = next.value.position;
      _quality = quality;
      failureStage = failureCode = null;
      next.addListener(_changed);
      notifyListeners();
      stage = 'release-previous';
      try {
        await previous?.dispose();
      } catch (_) {
        // The replacement is ready; an old platform release failure must
        // never send playback back to an already disposed controller.
      }
      if (_active &&
          _foreground &&
          pauseVersion == _pauseVersion &&
          !old.paused) {
        stage = 'play';
        await next.play();
      }
      _changed();
      return true;
    } catch (error) {
      failureStage = stage;
      final code = error is PlatformException ? error.code : null;
      failureCode = code != null && RegExp(r'^[\w.-]{1,64}$').hasMatch(code)
          ? code
          : error.runtimeType.toString();
      diagnostics.record('player.native-load-failed', {
        'stage': stage,
        'elapsedMs': elapsed.elapsedMilliseconds,
        'code': failureCode,
      });
      if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
        debugPrint(
          '[BAHA_NATIVE] load-failed stage=$stage '
          'elapsedMs=${elapsed.elapsedMilliseconds} code=$failureCode',
        );
      }
      if (next != null && next == video) {
        _blocked = true;
        try {
          await next.pause();
        } catch (_) {}
        _publish();
      } else {
        try {
          await next?.dispose().timeout(const Duration(seconds: 5));
        } catch (_) {
          // Creation can finish after its initialization deadline. Its
          // dispose future still releases it when the platform returns.
        }
      }
      if (!_disposed &&
          !_blocked &&
          generation == _generation &&
          previous != null) {
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
    final pauseVersion = _pauseVersion;
    final position = (timeline['position'] as num).toDouble();
    _seekRevision++;
    _position = position.clamp(0, state.duration);
    await video?.seekTo(Duration(milliseconds: (_position * 1000).round()));
    await video?.setPlaybackSpeed((timeline['rate'] as num).toDouble());
    await video?.setVolume(timeline['muted'] == true ? 0 : 1);
    if (_disposed) return;
    _active = true;
    if (timeline['paused'] == false &&
        _foreground &&
        pauseVersion == _pauseVersion) {
      await video?.play();
    }
    _changed();
  }

  Future<void> _samplePosition() async {
    if (_disposed || !_active || _polling || _seeking || video == null) return;
    _polling = true;
    final current = video;
    final revision = _seekRevision;
    try {
      final position = await current!.position;
      if (!_disposed &&
          current == video &&
          revision == _seekRevision &&
          position != null) {
        _position = position.inMilliseconds / 1000;
        _publish();
      }
    } catch (_) {
      // The next event/poll will carry the state after a source replacement.
    } finally {
      _polling = false;
    }
  }

  void _changed() {
    if (_disposed) return;
    _syncDownloadSampling();
    final position = video?.value.position;
    // video_player already publishes its native position every 100ms while
    // playing. Reuse that clock instead of running another platform poll.
    if (!_seeking && position != null && position != _lastVideoPosition) {
      _lastVideoPosition = position;
      _position = position.inMilliseconds / 1000;
    }
    _publish();
  }

  void _syncDownloadSampling() {
    final value = state;
    final sampling =
        !_disposed &&
        _foreground &&
        (value.phase == PlaybackPhase.loading ||
            (value.phase == PlaybackPhase.content && value.buffering));
    _downloadSpeed.setEnabled(sampling);
    if (!sampling) _downloadBytesPerSecond = 0;
  }

  void _downloadChanged(double speed) {
    if (_disposed) return;
    _downloadBytesPerSecond = speed;
    // Initialization already exposes the loading surface before handoff.
    if (active || video == null) onState(state);
  }

  void _publish() {
    if (_disposed) return;
    if (active) onState(state);
    if (!_disposed) notifyListeners();
  }

  Future<bool> command(String action, double? value) {
    if (action == 'pause') _pauseVersion++;
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
        final pauseVersion = _pauseVersion;
        await current.play();
        if (!_foreground || pauseVersion != _pauseVersion) {
          await current.pause();
        }
      case 'pause':
        await current.pause();
      case 'seek':
        if (value == null || !value.isFinite) return false;
        final previous = _position;
        _seekRevision++;
        _position = value.clamp(0, state.duration);
        _seeking = true;
        // Publish the new revision and its target as one change. A buffering
        // notification during the platform seek must not consume that
        // revision with the old media sample.
        _publish();
        try {
          await current.seekTo(
            Duration(milliseconds: (_position * 1000).round()),
          );
        } catch (_) {
          _seekRevision++;
          _position = previous;
          _publish();
          rethrow;
        } finally {
          _seeking = false;
          _lastVideoPosition = current.value.position;
        }
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
    _syncDownloadSampling();
    if (!value) await pause();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _downloadSpeed.dispose();
    _generation++;
    final current = video;
    current?.removeListener(_changed);
    video = null;
    if (current != null) {
      _released = current.dispose();
      unawaited(_released);
    }
    super.dispose();
  }
}
