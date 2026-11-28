import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart' show VideoViewType;

import '../core/models.dart';
import '../core/native_danmaku.dart';
import '../core/playback_state.dart';
import 'app_diagnostics.dart';
import 'native_http_api.dart';
import 'native_playback.dart';

/// Owns one HTTP authorization session and one decoder, without a browser.
class NativeHttpPlayback extends ChangeNotifier {
  NativeHttpPlayback({
    required this.document,
    required this.videoId,
    required this.preferredQuality,
    required this.onState,
    required this.diagnostics,
    this.skipAgeConfirmation = false,
    this.checkpoint,
    Duration Function()? now,
    NativeHttpApi? api,
    Future<NativeHttpCookieJar> Function()? cookieLoader,
  }) : _nowOverride = now,
       api =
           api ??
           NativeHttpApi(
             cookieLoader: cookieLoader,
             onEvent: (stage, code) {
               diagnostics.record('player.http', {
                 'stage': stage,
                 'code': code,
               });
               if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
                 debugPrint('[BAHA_HTTP] stage=$stage status=$code');
               }
             },
           );

  final String document, videoId;
  final int preferredQuality;
  final bool skipAgeConfirmation;
  final void Function(PlaybackState) onState;
  final AppDiagnostics diagnostics;
  final Json? checkpoint;
  final NativeHttpApi api;
  List<NativeDanmaku> _danmaku = const [];
  List<NativeDanmaku> get danmaku => _danmaku;
  final _sentDanmaku = <String, NativeDanmaku>{};
  bool danmakuLoading = false;
  String? danmakuFailureStage;
  final Duration Function()? _nowOverride;
  final _clock = Stopwatch()..start();
  final watch = NativeHttpWatchClock(), adWatch = NativeHttpWatchClock();
  NativeHttpPreparation? preparation;
  NativePlayback? player;
  PlaybackState _state = const PlaybackState();
  PlaybackState get state => _state;
  String? failureStage;
  int? failureCode;
  bool _disposed = false, _foreground = true, _ad = false;
  bool _loading = false, _finishingAd = false, _adStartPending = false;
  bool _adAcknowledged = false, _progressPending = false;
  bool _progressDirty = false, _progressForceEnded = false;
  bool _contentStarted = false, _wasPlaying = false, _wasActive = false;
  bool _endedReported = false;
  int _revision = 0;
  int _lastAdSeconds = -1;
  bool _lastCanSkipAd = false;
  double _nextProgress = 60;
  int acceptedProgress = 0;
  int acceptedPeriodicProgress = 0;
  Timer? _timer, _seekReportTimer;
  Future<void> _reports = Future.value();
  Future<void>? _waitBeforeInstall, _closing;
  Future<void>? _retiringPlayer;
  Future<void> released = Future.value();

  bool get needsConsent => !skipAgeConfirmation && _awaitingConsent;
  bool get _awaitingConsent =>
      !_disposed &&
      preparation != null &&
      player == null &&
      failureStage == null &&
      !_loading;
  bool get canSkipAd =>
      _foreground &&
      _ad &&
      _adAcknowledged &&
      adWatch.total >= 30 &&
      !_finishingAd &&
      failureStage == null;
  int get adSecondsRemaining => max(0, (30 - adWatch.total).ceil());
  bool get isAdvertisement => _ad;

  Future<void> prepare({
    bool applicationActive = true,
    bool nativeBackendAvailable = true,
    Future<void>? waitBeforeInstall,
  }) async {
    _foreground = applicationActive;
    _waitBeforeInstall = waitBeforeInstall;
    unawaited(waitBeforeInstall?.then<void>((_) {}, onError: (Object _) {}));
    final revision = ++_revision;
    if (!nativeBackendAvailable) {
      _fail(const NativeHttpException('native-backend-unavailable'), revision);
      return;
    }
    try {
      final result = await api.prepare(videoId);
      if (!_live(revision)) return;
      preparation = result;
      if (skipAgeConfirmation) {
        await consent();
      } else {
        _publish(const PlaybackState(phase: PlaybackPhase.age));
      }
    } catch (error) {
      _fail(error, revision);
    }
  }

  bool _live(int revision) => !_disposed && revision == _revision;

  Future<void> consent() async {
    if (!_awaitingConsent || !_foreground) return;
    final revision = _revision;
    _loading = true;
    _publish(const PlaybackState());
    try {
      api.consent();
      final ad = preparation!.ad;
      if (ad != null) {
        _ad = true;
        _lastAdSeconds = -1;
        _lastCanSkipAd = false;
        await _install(
          NativePlaybackSource.fromJson({
            'master': ad.playlist.toString(),
            'variants': <Json>[],
            'position': 0,
            'duration': 172800,
            'paused': false,
            'rate': 1,
            'muted': false,
          }),
          revision,
        );
      } else {
        await _content(revision);
      }
    } catch (error) {
      _fail(error, revision);
    } finally {
      if (_live(revision)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> skipAd() async {
    if (!canSkipAd) return;
    _finishingAd = true;
    final revision = _revision;
    notifyListeners();
    try {
      await player?.pause();
      await api.endAd(adWatch.total);
      if (!_live(revision)) return;
      await _content(revision);
    } catch (error) {
      _fail(error, revision);
    } finally {
      if (_live(revision)) {
        _finishingAd = false;
        notifyListeners();
      }
    }
  }

  Future<void> _content(int revision) async {
    _publish(const PlaybackState());
    final source = await api.source(
      position: (checkpoint?['position'] as num?)?.toDouble(),
      rate: (checkpoint?['rate'] as num?)?.toDouble() ?? 1,
      muted: checkpoint?['muted'] == true,
      paused: checkpoint?['paused'] == true,
    );
    if (!_live(revision)) return;
    await _install(
      source,
      revision,
      beforePlay: () async {
        await api.started();
        if (_live(revision)) unawaited(_loadDanmaku());
      },
    );
    if (!_live(revision)) return;
    _contentStarted = true;
    _wasActive = _foreground && !(player?.state.paused ?? true);
    _report(progress: true);
  }

  Future<void> loadDanmaku() async {
    if (_contentStarted) await _loadDanmaku();
  }

  Future<void> _loadDanmaku() async {
    if (_disposed || _ad || failureStage != null || danmakuLoading) return;
    final revision = _revision;
    danmakuLoading = true;
    danmakuFailureStage = null;
    notifyListeners();
    try {
      final items = await api.danmaku();
      if (!_live(revision) || failureStage != null) return;
      _danmaku = _mergeDanmaku(items);
      diagnostics.record('player.http-danmaku', {'count': items.length});
    } catch (error) {
      if (!_live(revision) || failureStage != null) return;
      final failure = error is NativeHttpException
          ? error
          : const NativeHttpException('danmaku-format');
      danmakuFailureStage = failure.stage;
      diagnostics.record('player.http-danmaku-failed', {
        'stage': failure.stage,
        'code': failure.code,
      });
    } finally {
      if (_live(revision)) {
        danmakuLoading = false;
        notifyListeners();
      }
    }
  }

  List<NativeDanmaku> _mergeDanmaku(List<NativeDanmaku> items) {
    if (_sentDanmaku.isEmpty) return items;
    return List.unmodifiable(
      ({
        for (final item in items) item.id: item,
        ..._sentDanmaku,
      }.values.toList()..sort((a, b) => a.time.compareTo(b.time))),
    );
  }

  void addSentDanmaku(NativeDanmaku item) {
    if (_disposed || !_contentStarted) return;
    final replacing =
        _sentDanmaku.containsKey(item.id) ||
        _danmaku.any((existing) => existing.id == item.id);
    _sentDanmaku[item.id] = item;
    if (replacing) {
      _danmaku = _mergeDanmaku(_danmaku);
    } else {
      var low = 0, high = _danmaku.length;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (_danmaku[middle].time <= item.time) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      final updated = List<NativeDanmaku>.of(_danmaku)..insert(low, item);
      _danmaku = List.unmodifiable(updated);
    }
    notifyListeners();
  }

  Future<void> _install(
    NativePlaybackSource source,
    int revision, {
    Future<void> Function()? beforePlay,
  }) async {
    if (_waitBeforeInstall case final pending?) await pending;
    _waitBeforeInstall = null;
    if (!_live(revision)) return;
    final old = player;
    player = null;
    if (old != null) {
      old.dispose();
      final release = _retiringPlayer = old.released;
      try {
        await release;
      } finally {
        _retiringPlayer = null;
      }
    }
    if (!_live(revision)) return;
    if (beforePlay != null) _ad = false;
    final next = NativePlayback(
      document: document,
      source: source,
      userAgent: api.userAgent,
      mediaUserAgent: api.mediaUserAgent,
      diagnostics: diagnostics,
      onState: _mediaChanged,
      viewType: !_ad && !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
          ? VideoViewType.platformView
          : VideoViewType.textureView,
    );
    player = next;
    notifyListeners();
    await next.setApplicationActive(_foreground);
    try {
      await next.initialize(_ad ? 0 : preferredQuality);
    } on StateError {
      throw const NativeHttpException('media-init');
    }
    if (!_live(revision)) return;
    await beforePlay?.call();
    if (!_live(revision)) return;
    final clock = _ad ? adWatch : watch;
    clock.discontinuity();
    clock.sample(
      position: source.position,
      now: _nowOverride?.call() ?? _clock.elapsed,
      playing: true,
    );
    await next.activate(
      applicationActive: _foreground,
      timeline: {
        'position': source.position,
        'paused': source.paused || !_foreground,
        'rate': source.rate,
        'muted': source.muted,
      },
    );
    if (!_live(revision)) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
  }

  PlaybackState _project(PlaybackState value) {
    if (!_ad) return value;
    return PlaybackState(
      phase: value.phase == PlaybackPhase.content
          ? PlaybackPhase.advertisement
          : value.phase,
      surfaceReady: value.surfaceReady,
      paused: value.paused,
      buffering: value.buffering,
      ended: value.ended,
      muted: value.muted,
      position: value.position,
      duration: value.duration,
      buffered: value.buffered,
      bufferedRanges: value.bufferedRanges,
      downloadBytesPerSecond: value.downloadBytesPerSecond,
      rate: value.rate,
      qualities: const [],
      quality: 0,
      hasDanmaku: false,
      danmaku: false,
    );
  }

  void _mediaChanged(PlaybackState value) {
    if (_disposed || failureStage != null) return;
    // Once skipAd() is transitioning out of a completed ad, ignore late EOF or
    // seek errors emitted by the retiring ad decoder.
    if (_ad && _finishingAd) return;
    _publish(_project(value), notify: false);
    if (value.phase == PlaybackPhase.error) {
      _fail(const NativeHttpException('media'), _revision);
      return;
    }
    _tick();
  }

  void _tick() {
    if (_disposed || failureStage != null || player == null) return;
    final value = player!.state;
    final running = _foreground && !value.paused && !value.buffering;
    final active = _foreground && !value.paused;
    if (_ad) {
      // Ads always start at zero. The command guard below rejects seeks,
      // speed/quality changes and replay. Only the decoder advances this
      // clock, including its final position when a 30-second ad completes.
      // EOF is the native decoder's completion receipt. The last sampled
      // position can precede it by one frame, and nominal 30-second HLS ads
      // whose #EXTINF segments sum to 29.999999 truncate to 29.999s in ms.
      final completed = value.ended
          ? (value.duration >= 29.5 && value.duration < 30
                ? 30.0
                : value.duration)
          : value.position;
      adWatch.sampleUnseekable(completed);
    } else {
      watch.sample(
        position: value.position,
        now: _nowOverride?.call() ?? _clock.elapsed,
        playing: running || (_wasPlaying && value.ended && _foreground),
        rate: value.rate,
        completed: value.ended && _foreground,
      );
    }
    final changedActive = _wasActive != active;
    _wasPlaying = running;
    _wasActive = active;
    if (_ad) {
      if (adWatch.total > 0 && !_adAcknowledged && !_adStartPending) {
        _adStartPending = true;
        final revision = _revision;
        unawaited(() async {
          try {
            await api.startAd();
            if (_live(revision)) {
              _adAcknowledged = true;
              _lastAdSeconds = adSecondsRemaining;
              _lastCanSkipAd = canSkipAd;
              notifyListeners();
              _tick();
            }
          } catch (error) {
            _fail(error, revision);
          }
        }());
      }
      if (value.ended && !_finishingAd) {
        if (canSkipAd) {
          unawaited(skipAd());
        } else if (_adAcknowledged && adWatch.total < 30) {
          _fail(
            const NativeHttpException('short-ad-needs-fallback'),
            _revision,
          );
        }
      }
      final seconds = adSecondsRemaining;
      final skip = canSkipAd;
      if (seconds != _lastAdSeconds || skip != _lastCanSkipAd) {
        _lastAdSeconds = seconds;
        _lastCanSkipAd = skip;
        notifyListeners();
      }
    } else if (_contentStarted && _closing == null) {
      if (value.ended && !_endedReported) {
        _endedReported = true;
        _report(progress: true, forceEnded: true);
      } else if (watch.total >= _nextProgress && !_progressPending) {
        _nextProgress = watch.total + 60;
        _report(progress: true, periodic: true);
      } else if (changedActive) {
        _report();
      }
    }
  }

  static bool _isTransientReportError(Object error) {
    if (error is! NativeHttpException) return false;
    if (error.stage.endsWith('-transport') ||
        error.stage.endsWith('-timeout')) {
      return true;
    }
    final code = error.code;
    return (error.stage == 'playback-state' || error.stage == 'progress') &&
        code != null &&
        (code == 429 || (code >= 500 && code <= 599));
  }

  void _report({
    bool progress = false,
    bool periodic = false,
    bool forceEnded = false,
  }) {
    if (_disposed || !_contentStarted || failureStage != null) return;
    if (progress) {
      _seekReportTimer?.cancel();
      _progressDirty = true;
      _progressForceEnded |= forceEnded;
      if (_progressPending) return;
      _progressPending = true;
    }
    final revision = _revision;
    final value = player!.state;
    final seconds = watch.total;
    _reports = _reports.then((_) async {
      if (!progress) {
        await _sendReport(revision, value, seconds);
        return;
      }
      var first = true;
      try {
        while (_progressDirty && _live(revision) && failureStage == null) {
          final ended = _progressForceEnded;
          _progressDirty = _progressForceEnded = false;
          await _sendReport(
            revision,
            player!.state,
            watch.total,
            progress: true,
            forceEnded: ended,
            periodic: first && periodic,
          );
          first = false;
        }
      } finally {
        _progressPending = false;
      }
    });
  }

  Future<void> _sendReport(
    int revision,
    PlaybackState value,
    double seconds, {
    bool progress = false,
    bool periodic = false,
    bool forceEnded = false,
  }) async {
    try {
      if (!_live(revision) || failureStage != null) return;
      await api.state(seconds);
      if (!_live(revision)) return;
      final position = forceEnded || value.ended
          ? value.duration
          : value.position;
      if (progress && await api.progress(position, value.duration)) {
        acceptedProgress++;
        if (periodic) acceptedPeriodicProgress++;
        diagnostics.record('player.http-progress', {
          'accepted': true,
          'deviceSession': api.usesDeviceSession,
          'position': position,
        });
      }
    } catch (error) {
      if (_isTransientReportError(error)) {
        final failure = error as NativeHttpException;
        diagnostics.record('player.http-report-failed', {
          'stage': failure.stage,
          'code': failure.code,
        });
      } else {
        _fail(error, revision);
      }
    }
  }

  Future<bool> command(String action, double? value) async {
    if (_disposed ||
        failureStage != null ||
        (!_foreground && action != 'pause')) {
      return false;
    }
    if (_ad && !const ['play', 'pause', 'mute'].contains(action)) return false;
    if (const ['seek', 'quality', 'rate'].contains(action)) {
      watch.discontinuity();
      adWatch.discontinuity();
    }
    try {
      final result = await player?.command(action, value) ?? false;
      if (result && action == 'seek' && !_disposed && _closing == null) {
        _seekReportTimer?.cancel();
        _seekReportTimer = Timer(
          const Duration(milliseconds: 1500),
          () => _report(progress: true),
        );
      }
      return result;
    } catch (error) {
      _fail(error, _revision);
      return false;
    }
  }

  Future<void> setApplicationActive(bool active) async {
    _foreground = active;
    watch.discontinuity();
    adWatch.discontinuity();
    await player?.setApplicationActive(active);
    if (!active && _contentStarted) _report(progress: true);
    if (!_disposed) {
      _lastCanSkipAd = canSkipAd;
      notifyListeners();
    }
    if (active && skipAgeConfirmation) await consent();
  }

  void _publish(PlaybackState value, {bool notify = true}) {
    if (_disposed) return;
    _state = value;
    onState(value);
    if (notify && !_disposed) notifyListeners();
  }

  void _fail(Object error, int revision) {
    if (!_live(revision) || failureStage != null) return;
    final failure = error is NativeHttpException
        ? error
        : const NativeHttpException('protocol-format');
    failureStage = failure.stage;
    failureCode = failure.code;
    _timer?.cancel();
    _seekReportTimer?.cancel();
    unawaited(player?.pause().catchError((Object _) {}));
    diagnostics.record('player.http-failed', {
      'stage': failure.stage,
      'code': failure.code,
    });
    if (const bool.fromEnvironment('BAHA_DIAGNOSTICS')) {
      debugPrint(
        '[BAHA_HTTP] failed=${failure.stage} code=${failure.code} '
        'adSeconds=${adWatch.total} duration=${player?.state.duration}',
      );
    }
    _publish(const PlaybackState(phase: PlaybackPhase.error));
  }

  /// Flush the final progress before cancelling this episode's requests.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_disposed) return released;
    _seekReportTimer?.cancel();
    try {
      await player?.pause();
    } finally {
      try {
        if (_contentStarted && failureStage == null) {
          _report(progress: true);
          await _reports;
        }
      } finally {
        dispose();
        await released;
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    _timer?.cancel();
    _seekReportTimer?.cancel();
    _danmaku = const [];
    _sentDanmaku.clear();
    api.dispose();
    final current = player;
    player = null;
    current?.dispose();
    released = current?.released ?? _retiringPlayer ?? Future.value();
    super.dispose();
  }
}
