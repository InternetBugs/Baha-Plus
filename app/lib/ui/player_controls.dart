import 'dart:math' as math;
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/playback_state.dart';
import 'buffered_playback_track.dart';

String formatDownloadSpeed(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return '0 B/s';
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  if (bytesPerSecond >= 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${bytesPerSecond.round()} B/s';
}

String formatPlaybackSeconds(int totalSeconds) {
  final value = math.max(0, totalSeconds);
  final hours = value ~/ 3600;
  final minutes = (value % 3600) ~/ 60;
  final secs = value % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
}

String formatPlaybackTime(double seconds) =>
    formatPlaybackSeconds(seconds.isFinite ? seconds.floor() : 0);

class PlaybackLoadingSpeed extends StatefulWidget {
  const PlaybackLoadingSpeed({required this.playback, super.key});
  final ValueListenable<PlaybackState> playback;

  @override
  State<PlaybackLoadingSpeed> createState() => _PlaybackLoadingSpeedState();
}

class _PlaybackLoadingSpeedState extends State<PlaybackLoadingSpeed> {
  late String _label = formatDownloadSpeed(
    widget.playback.value.downloadBytesPerSecond,
  );

  @override
  void initState() {
    super.initState();
    widget.playback.addListener(_onPlayback);
  }

  @override
  void didUpdateWidget(covariant PlaybackLoadingSpeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      oldWidget.playback.removeListener(_onPlayback);
      _label = formatDownloadSpeed(
        widget.playback.value.downloadBytesPerSecond,
      );
      widget.playback.addListener(_onPlayback);
    }
  }

  void _onPlayback() {
    final next = formatDownloadSpeed(
      widget.playback.value.downloadBytesPerSecond,
    );
    if (next != _label && mounted) {
      setState(() => _label = next);
    }
  }

  @override
  void dispose() {
    widget.playback.removeListener(_onPlayback);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: Text(
      _label,
      key: const ValueKey('player-loading-speed'),
      textDirection: TextDirection.ltr,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontFeatures: [FontFeature.tabularFigures()],
        shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
      ),
    ),
  );
}

@immutable
class PlayerChromeState {
  const PlayerChromeState({
    required this.phase,
    required this.surfaceReady,
    required this.canOperate,
    required this.canControl,
    required this.paused,
    required this.muted,
    required this.buffering,
    required this.ended,
    required this.hasDanmaku,
    required this.browserError,
    required this.inOpWindow,
    required this.quality,
    required this.qualities,
    required this.duration,
    required this.rate,
  });

  factory PlayerChromeState.fromPlayback(
    PlaybackState state, {
    required bool browserError,
  }) => PlayerChromeState(
    phase: state.phase,
    surfaceReady: state.surfaceReady,
    canOperate: state.canOperate,
    canControl: state.canControl,
    paused: state.paused,
    muted: state.muted,
    buffering: state.buffering,
    ended: state.ended,
    hasDanmaku: state.hasDanmaku,
    browserError: browserError,
    inOpWindow: state.duration >= 300 && state.position < 240,
    quality: state.quality,
    qualities: state.qualities,
    duration: state.duration,
    rate: state.rate,
  );

  final PlaybackPhase phase;
  final bool surfaceReady, canOperate, canControl, paused, muted, buffering;
  final bool ended, hasDanmaku, browserError, inOpWindow;
  final int quality;
  final List<int> qualities;
  final double duration, rate;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayerChromeState &&
          phase == other.phase &&
          surfaceReady == other.surfaceReady &&
          canOperate == other.canOperate &&
          canControl == other.canControl &&
          paused == other.paused &&
          muted == other.muted &&
          buffering == other.buffering &&
          ended == other.ended &&
          hasDanmaku == other.hasDanmaku &&
          browserError == other.browserError &&
          inOpWindow == other.inOpWindow &&
          quality == other.quality &&
          listEquals(qualities, other.qualities) &&
          duration == other.duration &&
          rate == other.rate;

  @override
  int get hashCode => Object.hash(
    phase,
    surfaceReady,
    canOperate,
    canControl,
    paused,
    muted,
    buffering,
    ended,
    hasDanmaku,
    browserError,
    inOpWindow,
    quality,
    Object.hashAll(qualities),
    duration,
    rate,
  );
}

class PlaybackProgressBar extends StatefulWidget {
  const PlaybackProgressBar({
    required this.playback,
    required this.active,
    required this.seekable,
    required this.thumbRadius,
    required this.color,
    required this.label,
    required this.scrub,
    required this.onBeginScrub,
    required this.onUpdateScrub,
    required this.onCommitScrub,
    required this.onCancelScrub,
    super.key,
  });

  final ValueListenable<PlaybackState> playback;
  final bool active, seekable;
  final double thumbRadius;
  final Color color;
  final String label;
  final ValueListenable<double?> scrub;
  final ValueChanged<double> onBeginScrub;
  final ValueChanged<double> onUpdateScrub;
  final VoidCallback onCommitScrub;
  final VoidCallback onCancelScrub;

  @override
  State<PlaybackProgressBar> createState() => _PlaybackProgressBarState();
}

class _PlaybackProgressBarState extends State<PlaybackProgressBar> {
  late PlaybackState _state;

  @override
  void initState() {
    super.initState();
    _state = widget.playback.value;
    if (widget.active) {
      widget.playback.addListener(_onPlayback);
      widget.scrub.addListener(_onScrub);
    }
  }

  @override
  void didUpdateWidget(covariant PlaybackProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      if (oldWidget.active) oldWidget.playback.removeListener(_onPlayback);
      _state = widget.playback.value;
      if (widget.active) widget.playback.addListener(_onPlayback);
    } else if (oldWidget.active != widget.active) {
      if (widget.active) {
        _state = widget.playback.value;
        widget.playback.addListener(_onPlayback);
      } else {
        widget.playback.removeListener(_onPlayback);
      }
    }
    if (oldWidget.scrub != widget.scrub) {
      if (oldWidget.active) oldWidget.scrub.removeListener(_onScrub);
      if (widget.active) widget.scrub.addListener(_onScrub);
    } else if (oldWidget.active != widget.active) {
      if (widget.active) {
        widget.scrub.addListener(_onScrub);
      } else {
        widget.scrub.removeListener(_onScrub);
      }
    }
  }

  void _onPlayback() {
    if (!mounted || !widget.active) return;
    final next = widget.playback.value;
    final scrubbing = widget.scrub.value != null;
    final bufferSame =
        next.duration == _state.duration &&
        next.buffered == _state.buffered &&
        listEquals(next.bufferedRanges, _state.bufferedRanges);
    if (bufferSame) {
      if (scrubbing || next.position == _state.position) return;
      final minDelta = next.duration > 0
          ? math.min(0.25, next.duration / 720.0)
          : 0.25;
      final atEndpoint = next.position <= 0 || next.position >= next.duration;
      if (!atEndpoint && (next.position - _state.position).abs() < minDelta) {
        return;
      }
    }
    setState(() => _state = next);
  }

  void _onScrub() {
    if (!mounted || !widget.active) return;
    setState(() => _state = widget.playback.value);
  }

  @override
  void dispose() {
    if (widget.active) {
      widget.playback.removeListener(_onPlayback);
      widget.scrub.removeListener(_onScrub);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = _state.duration;
    final position = (widget.scrub.value ?? _state.position).clamp(
      0.0,
      duration,
    );
    return RepaintBoundary(
      child: SizedBox(
        height: widget.thumbRadius * 2 + 16,
        child: Semantics(
          label: widget.label,
          child: Listener(
            onPointerCancel: (_) => widget.onCancelScrub(),
            child: BufferedPlaybackTrack(
              key: const ValueKey('player-buffered-track'),
              state: _state,
              color: widget.color,
              child: GlassSlider(
                key: const ValueKey('player-progress-slider'),
                value: position,
                max: duration > 0 ? duration : 1,
                thumbRadius: widget.thumbRadius,
                trackHeight: 4,
                activeColor: widget.color,
                inactiveColor: Colors.transparent,
                onChangeStart: widget.seekable ? widget.onBeginScrub : null,
                onChanged: widget.seekable ? widget.onUpdateScrub : null,
                onChangeEnd: widget.seekable
                    ? (_) => widget.onCommitScrub()
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum PlaybackTimeFormat { combined, position, duration }

class PlaybackTimeText extends StatefulWidget {
  const PlaybackTimeText({
    required this.playback,
    required this.active,
    required this.scrub,
    required this.style,
    this.format = PlaybackTimeFormat.combined,
    super.key,
  });

  final ValueListenable<PlaybackState> playback;
  final bool active;
  final ValueListenable<double?> scrub;
  final TextStyle style;
  final PlaybackTimeFormat format;

  @override
  State<PlaybackTimeText> createState() => _PlaybackTimeTextState();
}

class _PlaybackTimeTextState extends State<PlaybackTimeText> {
  late int _positionSeconds;
  late int _durationSeconds;

  void _capture() {
    final state = widget.playback.value;
    final duration = state.duration;
    final position = (widget.scrub.value ?? state.position).clamp(
      0.0,
      duration,
    );
    _positionSeconds = position.floor();
    _durationSeconds = duration.floor();
  }

  @override
  void initState() {
    super.initState();
    _capture();
    if (widget.active) {
      widget.playback.addListener(_onPlayback);
      widget.scrub.addListener(_onPlayback);
    }
  }

  @override
  void didUpdateWidget(covariant PlaybackTimeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      if (oldWidget.active) oldWidget.playback.removeListener(_onPlayback);
      _capture();
      if (widget.active) widget.playback.addListener(_onPlayback);
    } else if (oldWidget.active != widget.active) {
      if (widget.active) {
        _capture();
        widget.playback.addListener(_onPlayback);
      } else {
        widget.playback.removeListener(_onPlayback);
      }
    }
    if (oldWidget.scrub != widget.scrub) {
      if (oldWidget.active) oldWidget.scrub.removeListener(_onPlayback);
      _capture();
      if (widget.active) widget.scrub.addListener(_onPlayback);
    } else if (oldWidget.active != widget.active) {
      if (widget.active) {
        widget.scrub.addListener(_onPlayback);
      } else {
        widget.scrub.removeListener(_onPlayback);
      }
    }
  }

  void _onPlayback() {
    if (!mounted || !widget.active) return;
    final state = widget.playback.value;
    final duration = state.duration;
    final position = (widget.scrub.value ?? state.position).clamp(
      0.0,
      duration,
    );
    final posSec = position.floor();
    final durSec = duration.floor();
    final changed = switch (widget.format) {
      PlaybackTimeFormat.combined =>
        posSec != _positionSeconds || durSec != _durationSeconds,
      PlaybackTimeFormat.position => posSec != _positionSeconds,
      PlaybackTimeFormat.duration => durSec != _durationSeconds,
    };
    if (!changed) return;
    setState(() {
      _positionSeconds = posSec;
      _durationSeconds = durSec;
    });
  }

  @override
  void dispose() {
    if (widget.active) {
      widget.playback.removeListener(_onPlayback);
      widget.scrub.removeListener(_onPlayback);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = switch (widget.format) {
      PlaybackTimeFormat.combined =>
        '${formatPlaybackSeconds(_positionSeconds)} / ${formatPlaybackSeconds(_durationSeconds)}',
      PlaybackTimeFormat.position => formatPlaybackSeconds(_positionSeconds),
      PlaybackTimeFormat.duration => formatPlaybackSeconds(_durationSeconds),
    };
    return RepaintBoundary(
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        style: widget.style,
      ),
    );
  }
}
