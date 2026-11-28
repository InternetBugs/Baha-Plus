import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../core/models.dart';
import '../core/playback_state.dart';
import 'app_diagnostics.dart';
import 'native_download_speed.dart';
import 'native_hls_cache.dart';

class NativePlaybackSource {
  NativePlaybackSource.fromJson(
    Json json, {
    Map<Uri, String> seededPlaylists = const {},
  }) : master = mediaUri(json['master']),
       variants = parseVariants(json['variants']),
       position = (json['position'] as num).toDouble(),
       duration = (json['duration'] as num).toDouble(),
       rate = (json['rate'] as num).toDouble(),
       paused = json['paused'] as bool,
       muted = json['muted'] as bool,
       seededPlaylists = Map.unmodifiable(seededPlaylists) {
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
  final Map<Uri, String> seededPlaylists;
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
    required super.viewType,
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

class _QueuedSeek {
  _QueuedSeek(this.position);
  double position;
  late final Future<bool> result;
}

/// AVPlayer/ExoPlayer owns the video surface and actual media clock.
/// Media URLs never enter logs or preferences.
class NativePlayback extends ChangeNotifier {
  NativePlayback({
    required this.document,
    required this.source,
    required this.userAgent,
    this.mediaUserAgent,
    required this.onState,
    this.viewType = VideoViewType.textureView,
    this.initializeTimeout = const Duration(seconds: 35),
    this.retryDelay = const Duration(milliseconds: 300),
    AppDiagnostics? diagnostics,
    NativeHlsCache Function()? cacheFactory,
  }) : diagnostics = diagnostics ?? AppDiagnostics.instance,
       _cacheFactory = cacheFactory;

  final AppDiagnostics diagnostics;
  final String document, userAgent;

  /// Media CDN identity, kept apart from the official-site [userAgent].
  final String? mediaUserAgent;
  final NativePlaybackSource source;
  final VideoViewType viewType;
  final Duration initializeTimeout;
  final Duration retryDelay;
  final void Function(PlaybackState) onState;
  final NativeHlsCache Function()? _cacheFactory;
  late final List<int> _qualities = List<int>.unmodifiable(
    source.variants.keys.toList()..sort((a, b) => b.compareTo(a)),
  );
  NativeHlsCache? _cache;
  late final List<String> _downloadSources = [
    source.master.toString(),
    ...source.variants.values.map((uri) => uri.toString()),
  ];
  late final _downloadSpeed = NativeDownloadSpeed(
    onSpeed: _downloadChanged,
    counters: _cache == null
        ? null
        : () {
            final cache = _cache;
            return cache == null
                ? const <String, int>{}
                : {'bytes': cache.downloadedBytes, 'source': 0};
          },
  );
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
  _QueuedSeek? _queuedSeek;
  Future<bool>? _loading;
  Future<void>? _retiring;
  Future<void> _released = Future.value();
  PlaybackState? _cachedState;
  VideoPlayerValue? _cachedVideoValue;
  int _cachedCacheVersion = -1;
  List<DurationRange>? _cachedRawBuffered;
  double _cachedBufferedDuration = -1;
  int _cachedBufferedQuality = -1;
  int _cachedBufferedCacheVersion = -1;
  List<PlaybackBufferRange> _cachedMergedRanges = const [];
  double _cachedBufferedEnd = 0;
  static final _nonPrintableAsciiPattern = RegExp(r'[^\x20-\x7E]+');
  static final _errorCodePattern = RegExp(r'^[\w.-]{1,64}$');

  bool get active => _active && !_disposed;
  int get seekRevision => _seekRevision;
  Future<void> get released => _released;
  int get quality => _quality;
  double get duration {
    final value = video?.value;
    return value?.isInitialized == true
        ? value!.duration.inMilliseconds / 1000
        : source.duration;
  }

  bool get isPaused => video?.value.isPlaying != true;

  void _invalidateState() => _cachedState = null;

  PlaybackState get state {
    final value = video?.value;
    final cacheVersion = _cache?.version ?? 0;
    final cached = _cachedState;
    if (cached != null &&
        identical(value, _cachedVideoValue) &&
        cacheVersion == _cachedCacheVersion) {
      return cached;
    }
    final duration = value?.isInitialized == true
        ? value!.duration.inMilliseconds / 1000
        : source.duration;
    final rawBuffered = value?.buffered;
    List<PlaybackBufferRange> mergedRanges;
    double bufferedEnd;
    if (identical(rawBuffered, _cachedRawBuffered) &&
        duration == _cachedBufferedDuration &&
        _quality == _cachedBufferedQuality &&
        cacheVersion == _cachedBufferedCacheVersion) {
      mergedRanges = _cachedMergedRanges;
      bufferedEnd = _cachedBufferedEnd;
    } else {
      final bufferedRanges = <PlaybackBufferRange>[];
      for (final range in rawBuffered ?? const <DurationRange>[]) {
        final start = (range.start.inMilliseconds / 1000).clamp(0.0, duration);
        final end = range.end.inMilliseconds / 1000;
        if (end > start) {
          bufferedRanges.add((start: start, end: end.clamp(0.0, duration)));
        }
      }
      final media = _quality == 0 ? source.master : source.variants[_quality]!;
      for (final range
          in _cache?.bufferedRanges(media) ?? const <PlaybackBufferRange>[]) {
        final start = range.start.clamp(0.0, duration);
        final end = range.end.clamp(0.0, duration);
        if (end > start) bufferedRanges.add((start: start, end: end));
      }
      if (bufferedRanges.isEmpty) {
        mergedRanges = const [];
        bufferedEnd = 0;
      } else {
        if (bufferedRanges.length > 1) {
          bufferedRanges.sort((a, b) => a.start.compareTo(b.start));
        }
        final merged = <PlaybackBufferRange>[];
        for (final range in bufferedRanges) {
          if (merged.isNotEmpty && range.start <= merged.last.end) {
            final last = merged.removeLast();
            merged.add((
              start: last.start,
              end: range.end > last.end ? range.end : last.end,
            ));
          } else {
            merged.add(range);
          }
        }
        mergedRanges = List.unmodifiable(merged);
        bufferedEnd = merged.last.end;
      }
      _cachedRawBuffered = rawBuffered;
      _cachedBufferedDuration = duration;
      _cachedBufferedQuality = _quality;
      _cachedBufferedCacheVersion = cacheVersion;
      _cachedMergedRanges = mergedRanges;
      _cachedBufferedEnd = bufferedEnd;
    }
    final built = PlaybackState(
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
      buffered: bufferedEnd,
      bufferedRanges: mergedRanges,
      downloadBytesPerSecond: _downloadBytesPerSecond,
      rate: value?.playbackSpeed ?? source.rate,
      qualities: _qualities,
      quality: _quality,
      hasDanmaku: true,
      danmaku: true,
    );
    _cachedState = built;
    _cachedVideoValue = value;
    _cachedCacheVersion = cacheVersion;
    return built;
  }

  Future<void> initialize(int preferredQuality) async {
    if (_cacheFactory != null ||
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)) {
      final cache = _cache =
          _cacheFactory?.call() ??
          NativeHlsCache(
            headers: _mediaHeaders,
            onChanged: _publish,
            onDiagnostic: diagnostics.record,
          );
      try {
        source.seededPlaylists.forEach(cache.seedPlaylist);
        await cache.start();
      } catch (error) {
        await cache.close();
        if (_disposed) return;
        _cache = null;
        diagnostics.record('player.native-cache-unavailable', {
          'code': error.runtimeType.toString(),
        });
      }
      if (_disposed) {
        await cache.close();
        return;
      }
    }
    _downloadSpeed.setEnabled(_foreground);
    unawaited(_downloadSpeed.start(document, _downloadSources));
    _quality = source.variants.containsKey(preferredQuality)
        ? preferredQuality
        : 0;
    _position = source.position;
    _invalidateState();
    var loaded = await _load(_quality, initial: true);
    if (!loaded && _cache != null) {
      // Some iOS releases refuse the loopback playlist before decoding
      // anything. Playback must survive that: drop the session cache and load
      // the signed CDN playlist directly.
      final cache = _cache;
      final code = failureCode;
      _cache = null;
      _cachedBufferedCacheVersion = -1;
      _invalidateState();
      _downloadChanged(0);
      unawaited(_downloadSpeed.usePlatformCounters(document, _downloadSources));
      await cache?.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      if (_disposed) return;
      loaded = await _load(_quality, initial: true);
      diagnostics.record('player.native-cache-bypass', {
        'code': code,
        'fallback': loaded,
      });
    } else if (!loaded && !_disposed && failureStage == 'initialize') {
      final code = failureCode;
      if (retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
        if (_disposed) return;
      }
      loaded = await _load(_quality, initial: true);
      diagnostics.record('player.native-load-retry', {
        'code': code,
        'recovered': loaded,
      });
    }
    if (!loaded) throw StateError('Native media initialization failed');
    _syncDownloadSampling();
  }

  Map<String, String> get _mediaHeaders => {
    'Origin': 'https://ani.gamer.com.tw',
    'Referer': 'https://ani.gamer.com.tw/animeVideo.php',
    'User-Agent': mediaUserAgent ?? userAgent,
  };

  /// AVPlayer/ExoPlayer report only the platform error text, which names the
  /// failing layer. Keep a bounded printable copy; diagnostics also strips any
  /// URL or path it may embed.
  static String _describeFailure(Object error) {
    if (error is! PlatformException) return '';
    final text = error.message
        ?.replaceAll(_nonPrintableAsciiPattern, ' ')
        .trim();
    if (text == null || text.isEmpty) return '';
    return text.length > 320 ? text.substring(0, 320) : text;
  }

  Future<bool> _load(int quality, {bool initial = false}) async {
    final loading = _loading = _loadController(quality, initial: initial);
    try {
      return await loading;
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
  }

  Future<void> _retire(VideoPlayerController controller) {
    final release = controller.dispose().catchError((Object _) {});
    final previous = _retiring;
    final retiring = _retiring = previous == null
        ? release
        : Future.wait<void>([previous, release]);
    unawaited(
      retiring.then((_) {
        if (identical(_retiring, retiring)) _retiring = null;
      }),
    );
    return retiring;
  }

  Future<bool> _loadController(int quality, {required bool initial}) async {
    final generation = ++_generation;
    final pauseVersion = _pauseVersion;
    final previous = video;
    var stage = 'create';
    final elapsed = Stopwatch()..start();
    VideoPlayerController? next;
    var installed = false, resumePrevious = false;
    try {
      final media = quality == 0 ? source.master : source.variants[quality]!;
      next = _SeekAwareVideoPlayerController(
        _cache?.playlist(media) ?? media,
        httpHeaders: _cache == null ? _mediaHeaders : const {},
        viewType: viewType,
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: false,
          // Our lifecycle guard owns pause intent, including source changes.
          // Disable the plugin observer that otherwise resumes on foreground.
          allowBackgroundPlayback: true,
          // PlaybackEnvironment is the sole owner of the app's idle timer.
          preventsDisplaySleepDuringVideoPlayback: false,
        ),
      );
      stage = 'initialize';
      await next.initialize().timeout(initializeTimeout);
      if (_disposed || generation != _generation) {
        await next.dispose();
        return false;
      }
      final old = state;
      stage = 'rate';
      final rate = initial ? source.rate : old.rate;
      if (next.value.playbackSpeed != rate) await next.setPlaybackSpeed(rate);
      stage = 'volume';
      final volume = (initial ? source.muted : old.muted) ? 0.0 : 1.0;
      if (next.value.volume != volume) await next.setVolume(volume);
      if (previous != null && previous.value.isPlaying) {
        stage = 'pause-previous';
        resumePrevious = true;
        await previous.pause();
      }
      final position = initial ? source.position : _position;
      stage = 'seek';
      final target = Duration(milliseconds: (position * 1000).round());
      if (next.value.position != target) await next.seekTo(target);
      if (_disposed || generation != _generation) {
        await next.dispose();
        return false;
      }
      previous?.removeListener(_changed);
      video = next;
      installed = true;
      _position = next.value.position.inMilliseconds / 1000;
      _lastVideoPosition = next.value.position;
      _quality = quality;
      failureStage = failureCode = null;
      _invalidateState();
      next.addListener(_changed);
      notifyListeners();
      if (active &&
          _foreground &&
          pauseVersion == _pauseVersion &&
          resumePrevious) {
        stage = 'play';
        await next.play();
        if (!_disposed && (!_foreground || pauseVersion != _pauseVersion)) {
          await next.pause();
        }
      }
      _changed();
      return true;
    } catch (error) {
      failureStage = stage;
      final code = error is PlatformException ? error.code : null;
      failureCode = code != null && _errorCodePattern.hasMatch(code)
          ? code
          : error.runtimeType.toString();
      final detail = _describeFailure(error);
      diagnostics.record('player.native-load-failed', {
        'stage': stage,
        'elapsedMs': elapsed.elapsedMilliseconds,
        'code': failureCode,
        if (detail.isNotEmpty) 'detail': detail,
      });
      if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
        debugPrint(
          '[BAHA_NATIVE] load-failed stage=$stage '
          'elapsedMs=${elapsed.elapsedMilliseconds} code=$failureCode',
        );
      }
      if (installed && next != null && next == video) {
        _blocked = true;
        _invalidateState();
        try {
          await next.pause();
        } catch (_) {}
        _publish();
      } else if (!installed && next != null) {
        try {
          await _retire(next).timeout(const Duration(seconds: 5));
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
            resumePrevious) {
          await previous.play();
        }
      }
      return false;
    } finally {
      if (installed && previous != null) unawaited(_retire(previous));
    }
  }

  Future<void> activate({
    required bool applicationActive,
    required Json timeline,
  }) async {
    if (_disposed) return;
    _foreground = applicationActive;
    final pauseVersion = _pauseVersion;
    final current = video;
    if (current == null) return;
    final position = (timeline['position'] as num).toDouble();
    _seekRevision++;
    _position = position.clamp(0, duration);
    _invalidateState();
    final target = Duration(milliseconds: (_position * 1000).round());
    final rate = (timeline['rate'] as num).toDouble();
    final volume = timeline['muted'] == true ? 0.0 : 1.0;
    if (current.value.position != target) await current.seekTo(target);
    if (current.value.playbackSpeed != rate) {
      await current.setPlaybackSpeed(rate);
    }
    if (current.value.volume != volume) await current.setVolume(volume);
    if (_disposed) return;
    _active = true;
    if (timeline['paused'] == false &&
        _foreground &&
        pauseVersion == _pauseVersion) {
      await current.play();
    }
    _changed();
  }

  Future<void> _samplePosition({bool publish = true}) async {
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
        final seconds = position.inMilliseconds / 1000;
        if (seconds != _position) {
          _position = seconds;
          _invalidateState();
        }
        if (publish) _publish();
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
      _invalidateState();
    }
    _publish();
  }

  void _syncDownloadSampling() {
    final value = video?.value;
    final failed = _blocked || value?.hasError == true;
    final initialized = value?.isInitialized == true;
    final sampling =
        !_disposed &&
        _foreground &&
        !failed &&
        (!initialized || value!.isBuffering);
    _downloadSpeed.setEnabled(sampling);
    if (!sampling && _downloadBytesPerSecond != 0) {
      _downloadBytesPerSecond = 0;
      _invalidateState();
    }
  }

  void _downloadChanged(double speed) {
    if (_disposed) return;
    if (_downloadBytesPerSecond != speed) {
      _downloadBytesPerSecond = speed;
      _invalidateState();
    }
    // Initialization already exposes the loading surface before handoff.
    if (active || video == null) onState(state);
  }

  void _publish() {
    if (_disposed) return;
    if (active) onState(state);
    if (!_disposed) notifyListeners();
  }

  Future<bool> command(String action, double? value) {
    if (action == 'pause') {
      _pauseVersion++;
      final current = video;
      if (active && _loading != null && current?.value.isPlaying == true) {
        unawaited(current!.pause().catchError((Object _) {}));
      }
    }
    if (action == 'seek') {
      if (value == null || !value.isFinite) return Future.value(false);
      final queued = _queuedSeek;
      if (queued != null) {
        queued.position = value;
        return queued.result;
      }
      final seek = _queuedSeek = _QueuedSeek(value);
      seek.result = _commands.then((_) {
        if (identical(_queuedSeek, seek)) _queuedSeek = null;
        return _command(action, seek.position);
      });
      _commands = seek.result.catchError((_) => false);
      return seek.result;
    }
    _queuedSeek = null;
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
        _position = value.clamp(0, duration);
        _invalidateState();
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
          _invalidateState();
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
    if (action != 'rate' && action != 'mute') {
      await _samplePosition(publish: false);
    }
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
    final loading = _loading;
    current?.removeListener(_changed);
    video = null;
    _invalidateState();
    _released = () async {
      try {
        await Future.wait<void>([
          if (current != null) current.dispose(),
          if (loading != null) loading.then<void>((_) {}),
          if (_cache case final cache?) cache.close(),
        ]);
      } finally {
        await _retiring;
      }
    }();
    unawaited(_released);
    super.dispose();
  }
}
