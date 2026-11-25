import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show BoxFit, Rect, applyBoxFit;
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'app_store.dart';

enum PictureInPictureMode { unavailable, available, entering, active }

/// Owns screen wake, picture in picture and system playback controls.
class PlaybackEnvironment {
  PlaybackEnvironment(
    this.store, {
    MethodChannel channel = const MethodChannel(
      'app.bahaplus.mobile/playback_environment',
    ),
    Duration Function()? now,
  }) : _channel = channel,
       _now = now {
    store.addListener(_sync);
    store.playback.addListener(_sync);
    _channel.setMethodCallHandler(_remoteCommand);
    if (_mobile) {
      _pictureInPictureChannel.setMethodCallHandler(_pictureInPictureEvent);
      unawaited(_loadPictureInPictureSupport());
    }
    _sync();
  }

  final AppStore store;
  final MethodChannel _channel;
  static const _pictureInPictureChannel = MethodChannel(
    'app.bahaplus.mobile/picture_in_picture',
  );
  final _pictureInPicture = ValueNotifier(PictureInPictureMode.unavailable);
  ({String id, String document, VideoPlayerController video})?
  _pictureInPictureRequest;
  Completer<bool>? _pictureInPictureStarted;
  int _pictureInPictureSequence = 0;

  ValueListenable<PictureInPictureMode> get pictureInPicture =>
      _pictureInPicture;
  bool get _inPictureInPicture =>
      _pictureInPicture.value == PictureInPictureMode.active;
  bool get keepsPlaybackInBackground =>
      defaultTargetPlatform == TargetPlatform.iOS &&
      (_pictureInPicture.value == PictureInPictureMode.entering ||
          _inPictureInPicture);
  bool get _acceptsControls =>
      store.playbackActive && (_foreground || _inPictureInPicture);
  bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  final Duration Function()? _now;
  final _clock = Stopwatch()..start();
  static const _diagnostics = bool.fromEnvironment('BAHA_DIAGNOSTICS');
  bool _foreground = true, _disposed = false;
  bool _hasSent = false;
  bool _lastActive = false, _lastNative = false;
  bool _lastKeepAwake = false, _lastPlaying = false;
  String _lastDocument = '', _lastTitle = '', _lastEpisode = '';
  double _lastDuration = -1, _lastRate = -1, _lastPosition = -1;
  Duration _lastSentAt = Duration.zero;
  Future<void> _updates = Future<void>.value();

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _sync();
  }

  Future<void> _loadPictureInPictureSupport() async {
    final supported = await _pictureInPictureCall('isSupported');
    if (!_disposed && supported == true) {
      _pictureInPicture.value = PictureInPictureMode.available;
    }
  }

  Future<T?> _pictureInPictureCall<T>(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      return await _pictureInPictureChannel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> enterPictureInPicture(Rect surface) async {
    final state = store.playback.value;
    final session = store.nativeHttpPlayback;
    final video = session?.player?.video;
    final fullscreen = store.playerFullscreen;
    if (_disposed ||
        _pictureInPicture.value != PictureInPictureMode.available ||
        !_foreground ||
        !store.applicationActive ||
        !store.browserVisible ||
        !store.showsPlayer ||
        store.playerLocked ||
        !state.canControl ||
        state.ended ||
        session?.isAdvertisement != false ||
        video == null ||
        !video.value.isInitialized ||
        video.value.size.isEmpty ||
        !surface.isFinite ||
        surface.isEmpty) {
      store.diagnostics.record('player.pip', {
        'stage': 'player-unavailable',
        'fullscreen': fullscreen,
        'foreground': _foreground,
      });
      return false;
    }

    final document = store.operation.id;
    final id = '$document:${++_pictureInPictureSequence}';
    final arguments = <String, Object>{'id': id, 'document': document};
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      arguments['source'] = video.dataSource;
    } else {
      final size = applyBoxFit(
        BoxFit.contain,
        video.value.size,
        surface.size,
      ).destination;
      final bounds = Rect.fromCenter(
        center: surface.center,
        width: size.width,
        height: size.height,
      );
      arguments.addAll({
        'left': bounds.left,
        'top': bounds.top,
        'right': bounds.right,
        'bottom': bounds.bottom,
        'aspectRatio': video.value.aspectRatio,
      });
    }
    final started = Completer<bool>();
    _pictureInPictureStarted = started;
    _pictureInPictureRequest = (id: id, document: document, video: video);
    store.diagnostics.record('player.pip', {
      'stage': 'requested',
      'fullscreen': fullscreen,
    });
    _pictureInPicture.value = PictureInPictureMode.entering;
    const timeout = Duration(seconds: 4);
    try {
      final accepted = await _pictureInPictureCall<bool>(
        'enter',
        arguments,
      ).timeout(timeout);
      if (accepted != true) {
        store.diagnostics.record('player.pip', {
          'stage': 'host-rejected',
          'fullscreen': fullscreen,
        });
        return false;
      }
      return await started.future.timeout(timeout);
    } on TimeoutException {
      store.diagnostics.record('player.pip', {
        'stage': 'host-timeout',
        'fullscreen': fullscreen,
      });
      return false;
    } finally {
      if (_pictureInPictureRequest?.id == id && !_inPictureInPicture) {
        _endPictureInPicture(stop: true);
      }
    }
  }

  Future<void> _pictureInPictureEvent(MethodCall call) async {
    final request = _pictureInPictureRequest;
    final arguments = call.arguments;
    if (request == null || arguments is! Map || request.id != arguments['id']) {
      return;
    }
    if (call.method == 'modeChanged') {
      final active = arguments['active'] == true;
      store.diagnostics.record('player.pip', {
        'stage': active ? 'started' : 'ended',
        'fullscreen': store.playerFullscreen,
        if (arguments['reason'] case final String reason) 'reason': reason,
        if (arguments['errorDomain'] case final String domain)
          'errorDomain': domain,
        if (arguments['errorCode'] case final int code) 'errorCode': code,
      });
      if (active) {
        _pictureInPicture.value = PictureInPictureMode.active;
        _pictureInPictureStarted?.complete(true);
        _pictureInPictureStarted = null;
        _sync();
      } else {
        _endPictureInPicture();
      }
    } else if (call.method == 'playingChanged' && _inPictureInPicture) {
      final playing = arguments['playing'];
      if (playing is bool && request.document == store.operation.id) {
        await store.controlPlayer(playing ? 'play' : 'pause');
      }
    }
  }

  void _endPictureInPicture({bool stop = false}) {
    final request = _pictureInPictureRequest;
    if (request == null) return;
    _pictureInPictureRequest = null;
    _pictureInPictureStarted?.complete(false);
    _pictureInPictureStarted = null;
    if (stop && defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(_pictureInPictureCall<void>('stop', {'id': request.id}));
    }
    _pictureInPicture.value = PictureInPictureMode.available;
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
    if (!_acceptsControls) {
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
    if (!_acceptsControls || !store.browserVisible || !store.showsPlayer) {
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
    if (_disposed || !_mobile) return;
    final state = store.playback.value;
    final active = store.browserVisible && store.showsPlayer;
    final native = store.usesNativePlayback;
    final document = store.operation.id;
    final request = _pictureInPictureRequest;
    if (request != null &&
        (!active ||
            request.document != document ||
            request.video != store.nativeHttpPlayback?.player?.video)) {
      _endPictureInPicture(stop: true);
      return;
    }
    final playing =
        active &&
        (_foreground || keepsPlaybackInBackground) &&
        state.canOperate &&
        !state.paused &&
        !state.ended;
    final keepAwake = playing && _foreground && !_inPictureInPicture;
    final title = store.playingAnime?.title ?? '';
    final episode = store.playingEpisodeLabel;
    final duration = state.duration;
    final rate = state.rate;
    final now = _now?.call() ?? _clock.elapsed;

    if (_hasSent &&
        _lastActive == active &&
        _lastNative == native &&
        _lastDocument == document &&
        _lastKeepAwake == keepAwake &&
        _lastPlaying == playing &&
        _lastTitle == title &&
        _lastEpisode == episode &&
        _lastDuration == duration &&
        _lastRate == rate) {
      if (!active) return;
      if (playing) {
        final elapsedSeconds = (now - _lastSentAt).inMicroseconds / 1e6;
        final extrapolated = _lastPosition + elapsedSeconds * rate;
        if ((state.position - extrapolated).abs() < 2.0) return;
      } else if (state.position.floor() == _lastPosition.floor()) {
        return;
      }
    }

    _hasSent = true;
    _lastActive = active;
    _lastNative = native;
    _lastDocument = document;
    _lastKeepAwake = keepAwake;
    _lastPlaying = playing;
    _lastTitle = title;
    _lastEpisode = episode;
    _lastDuration = duration;
    _lastRate = rate;
    _lastPosition = state.position;
    _lastSentAt = now;

    final body = <String, dynamic>{
      'active': active,
      'diagnostics': _diagnostics,
      'native': native,
      'document': document,
      'keepAwake': keepAwake,
      'playing': playing,
      'title': title,
      'episode': episode,
      'position': state.position.floor(),
      'duration': duration,
      'rate': rate,
    };
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
    _clock.stop();
    store.removeListener(_sync);
    store.playback.removeListener(_sync);
    _channel.setMethodCallHandler(null);
    if (_mobile) _pictureInPictureChannel.setMethodCallHandler(null);
    _endPictureInPicture(stop: true);
    _pictureInPicture.dispose();
    _updates = _updates.then(
      (_) => _send({'active': false, 'keepAwake': false}),
    );
  }
}
