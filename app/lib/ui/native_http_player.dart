import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../data/native_http_playback.dart';
import '../data/playback_environment.dart';
import 'native_http_rating.dart';
import 'native_video_surface.dart';
import 'player_page.dart';

class NativeHttpPlayer extends StatelessWidget {
  const NativeHttpPlayer({required this.store, this.environment, super.key});
  final AppStore store;
  final PlaybackEnvironment? environment;

  @override
  Widget build(BuildContext context) {
    final mode = environment?.pictureInPicture;
    if (mode == null) return _page(PictureInPictureMode.unavailable);
    return ValueListenableBuilder(
      valueListenable: mode,
      builder: (context, value, child) => _page(value),
    );
  }

  Widget _page(PictureInPictureMode mode) => PlayerPage(
    key: const ValueKey('app-playback-page'),
    store: store,
    videoOnly:
        mode == PictureInPictureMode.active &&
        defaultTargetPlatform == TargetPlatform.android,
    onEnterPictureInPicture: mode == PictureInPictureMode.available
        ? environment?.enterPictureInPicture
        : null,
    video: ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final session = store.nativeHttpPlayback;
        if (session == null) return const ColoredBox(color: Colors.black);
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) =>
              _surface(session, mode == PictureInPictureMode.active),
        );
      },
    ),
  );

  Widget _surface(NativeHttpPlayback session, bool pictureInPicture) {
    final player = session.player;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (player != null)
            NativeVideoSurface(
              key: ObjectKey(player),
              playback: player,
              danmaku: session.danmaku,
              settings: pictureInPicture
                  ? store.danmakuSettings.copyWith(enabled: false)
                  : store.danmakuSettings,
              errorLabel: store.t('playerPlaybackError'),
              retryLabel: store.t('retry'),
              onRetry: store.retryPlayback,
              suppressErrors: true,
            ),
          if (session.needsConsent)
            NativeHttpPlaybackConsent(
              rating: session.preparation!.rating,
              translate: store.t,
              onConfirm: store.applicationActive
                  ? () => unawaited(session.consent())
                  : null,
            ),
          if (session.isAdvertisement && player != null)
            Positioned(
              bottom: 8,
              right: 12,
              child: CupertinoButton.filled(
                key: const ValueKey('http-skip-ad'),
                onPressed: session.canSkipAd
                    ? () => unawaited(session.skipAd())
                    : null,
                child: Text(
                  session.canSkipAd
                      ? store.t('httpSkipAd')
                      : store
                            .t('httpAdCountdown')
                            .replaceAll(
                              '{seconds}',
                              '${session.adSecondsRemaining}',
                            ),
                ),
              ),
            ),
          if (session.failureStage != null)
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      store.t(switch (session.failureStage) {
                        'parent-verification-required' => 'httpParentRequired',
                        'verification-required' => 'officialVerificationHint',
                        'short-ad-needs-fallback' => 'httpUnsupportedAd',
                        'session-changed' => 'httpSessionChanged',
                        'native-backend-unavailable' => 'httpNativeRequired',
                        'video-id' => 'detailUnavailable',
                        _ => 'playerPlaybackError',
                      }),
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                    CupertinoButton(
                      key: const ValueKey('http-playback-retry'),
                      onPressed: store.retryPlayback,
                      child: Text(store.t('retry')),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class NativeHttpPlaybackConsent extends StatelessWidget {
  const NativeHttpPlaybackConsent({
    required this.rating,
    required this.translate,
    required this.onConfirm,
    super.key,
  });

  final int rating;
  final String Function(String) translate;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 42, 20, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              translate('httpPlaybackConsentTitle'),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              translate(nativeHttpRatingMessageKey(rating)),
              key: const ValueKey('http-playback-age-rating'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              translate('httpAgeConsent'),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            CupertinoButton.filled(
              key: const ValueKey('http-playback-consent'),
              onPressed: onConfirm,
              child: Text(translate('httpConfirmPlayback')),
            ),
          ],
        ),
      ),
    ),
  );
}
