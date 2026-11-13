import 'dart:async';

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/native_danmaku.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_http_api.dart';
import 'package:baha_plus/data/native_http_playback.dart';

/// Keeps interface fixtures independent of network, consent and decoding.
class PendingNativeHttpApi extends NativeHttpApi {
  @override
  Future<NativeHttpPreparation> prepare(String videoId) =>
      Completer<NativeHttpPreparation>().future;
}

class FakeHttpPlayback extends NativeHttpPlayback {
  FakeHttpPlayback(this.store, {this.onCommand})
    : super(
        document: store.operation.id,
        videoId: store.playingVideoId!,
        preferredQuality: store.preferredQuality,
        diagnostics: store.diagnostics,
        onState: (_) {},
        api: PendingNativeHttpApi(),
      );

  final AppStore store;
  final Future<bool> Function(String, double?)? onCommand;
  final sent = <NativeDanmaku>[];
  Completer<void>? closeGate;

  @override
  PlaybackState get state => store.playback.value;

  @override
  List<NativeDanmaku> get danmaku => sent;

  @override
  void addSentDanmaku(NativeDanmaku item) {
    sent.add(item);
    notifyListeners();
  }

  @override
  Future<bool> command(String action, double? value) async =>
      await onCommand?.call(action, value) ?? true;

  @override
  Future<void> setApplicationActive(bool active) async {
    if (!active) {
      await command('pause', null);
      final current = store.playback.value;
      store.playback.value = PlaybackState(
        phase: current.phase,
        surfaceReady: current.surfaceReady,
        paused: true,
        buffering: current.buffering,
        ended: current.ended,
        muted: current.muted,
        position: current.position,
        duration: current.duration,
        buffered: current.buffered,
        bufferedRanges: current.bufferedRanges,
        downloadBytesPerSecond: current.downloadBytesPerSecond,
        rate: current.rate,
        qualities: current.qualities,
        quality: current.quality,
        hasDanmaku: current.hasDanmaku,
        danmaku: current.danmaku,
      );
    }
  }

  @override
  Future<void> close() async {
    await closeGate?.future;
    dispose();
  }
}

Future<void> playFixture(
  AppStore store,
  Anime anime, {
  Episode? episode,
  Future<bool> Function(String, double?)? onCommand,
}) async {
  final previous = store.nativeHttpPlayback;
  final handler =
      onCommand ?? (previous is FakeHttpPlayback ? previous.onCommand : null);
  await store.play(anime, episode: episode);
  store.nativeHttpPlayback?.dispose();
  store.nativeHttpPlayback = FakeHttpPlayback(store, onCommand: handler);
}
