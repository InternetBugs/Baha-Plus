import 'dart:async';
import 'package:flutter/services.dart';

/// Samples media transfer counters, independently of playback rate or buffering
/// duration. The native hosts count player traffic rather than device traffic.
class NativeDownloadSpeed {
  NativeDownloadSpeed({
    required this.onSpeed,
    MethodChannel channel = const MethodChannel(
      'app.bahaplus.mobile/playback_download',
    ),
    int Function()? elapsedMicroseconds,
  }) : _channel = channel,
       _elapsedMicroseconds = elapsedMicroseconds;

  final void Function(double) onSpeed;
  final MethodChannel _channel;
  final int Function()? _elapsedMicroseconds;
  final _clock = Stopwatch()..start();
  String? _document;
  Timer? _timer;
  bool _supported = false, _enabled = false, _reading = false;
  int _revision = 0, _session = 0;
  int? _bytes, _source, _time;

  Future<void> start(String document, List<String> sources) async {
    _document = document;
    final session = ++_session;
    _revision++;
    try {
      final supported = await _channel.invokeMethod<bool>('start', {
        'document': document,
        'sources': sources,
      });
      if (session != _session) return;
      _supported = supported == true;
      _sync();
    } on MissingPluginException {
      // Desktop backends and older hosts can omit media transfer statistics.
    } on PlatformException {
      // Statistics must never delay or interrupt media initialization.
    }
  }

  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    _revision++;
    _reset();
    _sync();
  }

  void _reset() {
    _bytes = _source = _time = null;
  }

  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (!_supported || !_enabled || _document == null) return;
    unawaited(sample());
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(sample()),
    );
  }

  Future<void> sample() async {
    if (_reading || !_supported || !_enabled || _document == null) return;
    final revision = _revision;
    _reading = true;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('sample', {
        'document': _document,
      });
      if (revision != _revision) return;
      final bytes = result?['bytes'];
      final source = result?['source'];
      if (bytes is! int || bytes < 0 || source is! int || source < 0) {
        _reset();
        onSpeed(0);
        return;
      }
      final time = _elapsedMicroseconds?.call() ?? _clock.elapsedMicroseconds;
      final elapsed = _time == null ? 0 : time - _time!;
      final speed =
          _source == source && _bytes != null && bytes >= _bytes! && elapsed > 0
          ? (bytes - _bytes!) * Duration.microsecondsPerSecond / elapsed
          : 0.0;
      _bytes = bytes;
      _source = source;
      _time = time;
      onSpeed(speed.isFinite ? speed.clamp(0, 1e12) : 0);
    } on MissingPluginException {
      if (revision == _revision) onSpeed(0);
    } on PlatformException {
      if (revision == _revision) {
        _reset();
        onSpeed(0);
      }
    } finally {
      _reading = false;
    }
  }

  void dispose() {
    _session++;
    _revision++;
    _enabled = _supported = false;
    _timer?.cancel();
    final document = _document;
    _document = null;
    if (document != null) unawaited(_stop(document));
  }

  Future<void> _stop(String document) async {
    try {
      await _channel.invokeMethod<void>('stop', {'document': document});
    } on MissingPluginException {
      // Optional host channel.
    } on PlatformException {
      // The next start also replaces the previous counter session.
    }
  }
}
