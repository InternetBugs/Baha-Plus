import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

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
  bool _contentStarted = false, _wasPlaying = false, _endedReported = false;
  int _revision = 0;
  double _nextProgress = 60;
  int acceptedProgress = 0;
  int acceptedPeriodicProgress = 0;
  Timer? _timer;
  Future<void> _reports = Future.value();
  Future<void> released = Future.value();

  bool get needsConsent =>
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
  }) async {
    _foreground = applicationActive;
    final revision = ++_revision;
    if (!nativeBackendAvailable) {
      _fail(const NativeHttpException('native-backend-unavailable'), revision);
      return;
    }
    try {
      final result = await api.prepare(videoId);
      if (!_live(revision)) return;
      preparation = result;
      _publish(const PlaybackState(phase: PlaybackPhase.age));
    } catch (error) {
      _fail(error, revision);
    }
  }

  bool _live(int revision) => !_disposed && revision == _revision;

  Future<void> consent() async {
    if (!needsConsent || !_foreground) return;
    final revision = _revision;
    _loading = true;
    _publish(const PlaybackState());
    try {
      api.consent();
      final ad = preparation!.ad;
      if (ad != null) {
        _ad = true;
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
    _ad = false;
    await _install(
      source,
      revision,
      beforePlay: () async {
        await api.started();
        _contentStarted = true;
      },
    );
    if (!_live(revision)) return;
    unawaited(loadDanmaku());
    _report(progress: true);
  }

  Future<void> loadDanmaku() async {
    if (_disposed ||
        !_contentStarted ||
        failureStage != null ||
        danmakuLoading) {
      return;
    }
    final revision = _revision;
    danmakuLoading = true;
    danmakuFailureStage = null;
    notifyListeners();
    try {
      final items = await api.danmaku();
      if (!_live(revision)) return;
      _danmaku = _mergeDanmaku(items);
      diagnostics.record('player.http-danmaku', {'count': items.length});
    } catch (error) {
      if (!_live(revision)) return;
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

  List<NativeDanmaku> _mergeDanmaku(List<NativeDanmaku> items) =>
      List.unmodifiable(
        ({
          for (final item in items) item.id: item,
          ..._sentDanmaku,
        }.values.toList()..sort((a, b) => a.time.compareTo(b.time))),
      );

  void addSentDanmaku(NativeDanmaku item) {
    if (_disposed || !_contentStarted) return;
    _sentDanmaku[item.id] = item;
    _danmaku = _mergeDanmaku(_danmaku);
    notifyListeners();
  }

  Future<void> _install(
    NativePlaybackSource source,
    int revision, {
    Future<void> Function()? beforePlay,
  }) async {
    final old = player;
    player = null;
    old?.dispose();
    if (old != null) await old.released;
    if (!_live(revision)) return;
    final next = NativePlayback(
      document: document,
      source: source,
      userAgent: NativeHttpApi.userAgent,
      diagnostics: diagnostics,
      onState: _mediaChanged,
    );
    player = next;
    notifyListeners();
    await next.setApplicationActive(_foreground);
    await next.initialize(_ad ? 0 : preferredQuality);
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

  PlaybackState _project(PlaybackState value) => PlaybackState(
    phase: value.phase == PlaybackPhase.content && _ad
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
    qualities: _ad ? const [] : value.qualities,
    quality: _ad ? 0 : value.quality,
    hasDanmaku: !_ad && value.hasDanmaku,
    danmaku: !_ad && value.danmaku,
  );

  void _mediaChanged(PlaybackState value) {
    if (_disposed || failureStage != null) return;
    _publish(_project(value));
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
    if (_ad) {
      // Ads always start at zero. The command guard below rejects seeks,
      // speed/quality changes and replay. Only the decoder advances this
      // clock, including its final position when a 30-second ad completes.
      // EOF is the native decoder's completion receipt. The last sampled
      // position can precede it by one frame, so flush the completed duration.
      adWatch.sampleUnseekable(value.ended ? value.duration : value.position);
    } else {
      watch.sample(
        position: value.position,
        now: _nowOverride?.call() ?? _clock.elapsed,
        playing: running || (_wasPlaying && value.ended && _foreground),
        rate: value.rate,
        completed: value.ended && _foreground,
      );
    }
    final changedPlaying = _wasPlaying != running;
    _wasPlaying = running;
    if (_ad) {
      if (adWatch.total > 0 && !_adAcknowledged && !_adStartPending) {
        _adStartPending = true;
        final revision = _revision;
        unawaited(() async {
          try {
            await api.startAd();
            if (_live(revision)) {
              _adAcknowledged = true;
              notifyListeners();
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
      notifyListeners();
    } else if (_contentStarted) {
      if (watch.total >= _nextProgress && !_progressPending) {
        _nextProgress = watch.total + 60;
        _report(progress: true, periodic: true);
      } else if (value.ended && !_endedReported) {
        _endedReported = true;
        _report(progress: true);
      } else if (changedPlaying) {
        _report();
      }
    }
  }

  void _report({bool progress = false, bool periodic = false}) {
    if (_disposed || !_contentStarted || failureStage != null) return;
    if (progress) {
      if (_progressPending) return;
      _progressPending = true;
    }
    final revision = _revision;
    final value = player!.state;
    final seconds = watch.total;
    _reports = _reports.then((_) async {
      try {
        if (!_live(revision) || failureStage != null) return;
        await api.state(seconds);
        if (!_live(revision)) return;
        if (progress && await api.progress(value.position, value.duration)) {
          acceptedProgress++;
          if (periodic) acceptedPeriodicProgress++;
          diagnostics.record('player.http-progress', {
            'accepted': true,
            'deviceSession': api.usesDeviceSession,
            'position': value.position,
          });
        }
      } catch (error) {
        _fail(error, revision);
      } finally {
        if (_live(revision) && progress) _progressPending = false;
      }
    });
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
      if (result && action == 'seek') _report(progress: true);
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
    if (!_disposed) notifyListeners();
  }

  void _publish(PlaybackState value) {
    if (_disposed) return;
    _state = value;
    onState(value);
    if (!_disposed) notifyListeners();
  }

  void _fail(Object error, int revision) {
    if (!_live(revision) || failureStage != null) return;
    final failure = error is NativeHttpException
        ? error
        : const NativeHttpException('protocol-format');
    failureStage = failure.stage;
    failureCode = failure.code;
    _timer?.cancel();
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
  Future<void> close() async {
    if (_disposed) return released;
    await player?.pause();
    if (_contentStarted && failureStage == null) {
      _report(progress: true);
      try {
        await _reports.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Closing always releases the decoder even if the service is offline.
      }
    }
    dispose();
    await released;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    _timer?.cancel();
    _danmaku = const [];
    _sentDanmaku.clear();
    api.dispose();
    final current = player;
    player = null;
    current?.dispose();
    released = current?.released ?? Future.value();
    super.dispose();
  }
}
