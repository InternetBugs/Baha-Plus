import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app_store.dart';

/// Owns screen wake and system controls for the visible playback session.
class PlaybackEnvironment {
  PlaybackEnvironment(
    this.store, {
    MethodChannel channel = const MethodChannel(
      'app.bahaplus.mobile/playback_environment',
    ),
  }) : _channel = channel {
    store.addListener(_sync);
    store.playback.addListener(_sync);
    _channel.setMethodCallHandler(_remoteCommand);
    _sync();
  }

  final AppStore store;
  final MethodChannel _channel;
  static const _diagnostics = bool.fromEnvironment('BAHA_DIAGNOSTICS');
  bool _foreground = true, _disposed = false;
  String _last = '';
  Future<void> _updates = Future<void>.value();

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _sync();
  }

  Future<dynamic> _remoteCommand(MethodCall call) async {
    final arguments = call.arguments;
    final document = arguments is Map ? arguments['document'] : null;
    final rawRequestId = arguments is Map ? arguments['requestId'] : null;
    final requestId = rawRequestId is int && rawRequestId > 0
        ? rawRequestId
        : null;
    final rawSource = arguments is Map ? arguments['source'] : null;
    final source =
        const [
          'remote-command',
          'audio-interruption',
          'audio-route',
        ].contains(rawSource)
        ? rawSource as String
        : 'unknown';
    final rawAction = arguments is Map ? arguments['action'] : null;
    final action = rawAction == 'toggle' && !_disposed
        ? store.playback.value.paused
              ? 'play'
              : 'pause'
        : rawAction;
    final validAction = const ['play', 'pause', 'seek'].contains(action);

    dynamic reply(bool accepted, String reason, {bool? stateMatches}) {
      final current =
          !_disposed && document is String && document == store.operation.id;
      final state = current ? store.playback.value : null;
      final receipt = <String, dynamic>{
        'requestId': ?requestId,
        'accepted': accepted,
        'reason': reason,
        'action': validAction ? action : 'unknown',
        'stateMatches': stateMatches,
        if (state != null) 'paused': state.paused,
        if (state != null) 'position': state.position,
      };
      store.diagnostics.record('player.remote-command', {
        'accepted': accepted,
        'reason': reason,
        'action': validAction ? action : 'unknown',
        'stateMatches': stateMatches,
        'foreground': _foreground,
        if (state != null) 'phase': state.phase.name,
      });
      if (_diagnostics) {
        final event = {
          ...receipt,
          'stage': 'flutter-reply',
          'source': source,
          'documentCurrent': current,
          'foreground': _foreground,
          if (!_disposed) 'applicationActive': store.applicationActive,
          if (state != null) 'native': store.usesNativePlayback,
          if (state != null) 'phase': state.phase.name,
        };
        debugPrint('[BAHA_AUDIO] ${jsonEncode(event)}');
      }
      // Older hosts did not request a receipt and expect a boolean reply.
      return requestId == null ? accepted : receipt;
    }

    if (_disposed) return reply(false, 'disposed');
    if (call.method != 'remoteCommand') {
      return reply(false, 'unsupported-method');
    }
    if (rawRequestId != null && requestId == null) {
      return reply(false, 'invalid-request-id');
    }
    if (document is! String || document != store.operation.id) {
      return reply(false, 'stale-document');
    }
    if (!_foreground || !store.applicationActive) {
      return reply(false, 'not-foreground');
    }
    if (!validAction) return reply(false, 'unsupported-action');
    if (!store.browserVisible || !store.showsPlayer) {
      return reply(false, 'no-visible-player');
    }
    final state = store.playback.value;
    if (!state.canOperate && !(action == 'pause' && state.surfaceReady)) {
      return reply(false, 'not-operable');
    }
    double? seekPosition;
    if (action == 'seek') {
      final value = arguments['value'];
      if (!state.canControl || value is! num || !value.isFinite || value < 0) {
        return reply(false, 'invalid-seek');
      }
      seekPosition = value.toDouble();
    }
    try {
      await store.controlPlayer(action as String, seekPosition);
    } catch (_) {
      return reply(false, 'command-error');
    }
    if (_disposed || document != store.operation.id) {
      return reply(false, 'session-changed');
    }
    if (!_foreground ||
        !store.applicationActive ||
        !store.browserVisible ||
        !store.showsPlayer) {
      return reply(false, 'session-inactive');
    }
    final after = store.playback.value;
    final stateMatches = switch (action) {
      'pause' => after.paused,
      'play' => !after.paused && !after.ended,
      'seek' =>
        (after.position - seekPosition!.clamp(0, after.duration)).abs() <= .5,
      _ => false,
    };
    // AppStore currently returns void and may swallow a backend rejection.
    // This acknowledges dispatch and reports the observed state separately;
    // stateMatches must not be interpreted as proof of a hardware event.
    return reply(true, 'dispatched', stateMatches: stateMatches);
  }

  void _sync() {
    if (_disposed ||
        !const [
          TargetPlatform.iOS,
          TargetPlatform.android,
        ].contains(defaultTargetPlatform)) {
      return;
    }
    final state = store.playback.value;
    final active = store.browserVisible && store.showsPlayer;
    final playing =
        active &&
        _foreground &&
        state.canOperate &&
        !state.paused &&
        !state.ended;
    final body = <String, dynamic>{
      'active': active,
      'diagnostics': _diagnostics,
      'native': store.usesNativePlayback,
      'document': store.operation.id,
      'keepAwake': playing,
      'playing': playing,
      'title': store.playingAnime?.title ?? '',
      'episode': store.playingEpisodeLabel,
      'position': state.position.floor(),
      'duration': state.duration,
      'rate': state.rate,
    };
    final key = body.toString();
    if (_last == key) return;
    _last = key;
    _updates = _updates.then((_) => _send(body));
  }

  Future<void> _send(Map<String, dynamic> body) async {
    try {
      await _channel.invokeMethod<void>('update', body);
    } on MissingPluginException {
      // Desktop development and older native binaries have no host channel.
    } on PlatformException catch (error) {
      debugPrint('Unable to update playback environment: ${error.code}');
    }
  }

  void dispose() {
    _disposed = true;
    store.removeListener(_sync);
    store.playback.removeListener(_sync);
    _channel.setMethodCallHandler(null);
    _updates = _updates.then(
      (_) => _send({'active': false, 'keepAwake': false}),
    );
  }
}
