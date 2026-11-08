import 'dart:async';
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
  bool _foreground = true, _disposed = false;
  String _last = '';
  Future<void> _updates = Future<void>.value();

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _sync();
  }

  Future<dynamic> _remoteCommand(MethodCall call) async {
    if (_disposed || call.method != 'remoteCommand' || !_foreground) {
      return false;
    }
    final arguments = call.arguments;
    if (arguments is! Map || arguments['document'] != store.operation.id) {
      return false;
    }
    final action = arguments['action'] == 'toggle'
        ? store.playback.value.paused
              ? 'play'
              : 'pause'
        : arguments['action'];
    if (action != 'play' && action != 'pause' && action != 'seek') return false;
    if (!store.browserVisible ||
        !store.showsPlayer ||
        (!store.playback.value.canOperate &&
            !(action == 'pause' && store.playback.value.surfaceReady))) {
      return false;
    }
    if (action == 'seek') {
      final value = arguments['value'];
      if (!store.playback.value.canControl ||
          value is! num ||
          !value.isFinite) {
        return false;
      }
      await store.controlPlayer('seek', value.toDouble());
    } else {
      await store.controlPlayer(action as String);
    }
    return true;
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
