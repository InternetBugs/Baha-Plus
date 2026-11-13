import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../data/native_http_playback.dart';
import 'native_video_surface.dart';
import 'player_page.dart';

class NativeHttpPlayer extends StatelessWidget {
  const NativeHttpPlayer({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final session = store.nativeHttpPlayback!;
    return ListenableBuilder(
      listenable: Listenable.merge([session, store]),
      builder: (context, _) => PlayerPage(
        key: const ValueKey('app-playback-page'),
        store: store,
        video: _surface(session),
      ),
    );
  }

  Widget _surface(NativeHttpPlayback session) {
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
              settings: store.danmakuSettings,
              errorLabel: store.t('playerPlaybackError'),
              retryLabel: store.t('retry'),
              onRetry: store.retryPlayback,
              suppressErrors: true,
            ),
          if (session.needsConsent)
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 42, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      store.t('httpGuestPlayback'),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      store
                          .t('httpAgeConsent')
                          .replaceAll(
                            '{rating}',
                            '${session.preparation!.rating}',
                          ),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    CupertinoButton.filled(
                      key: const ValueKey('http-playback-consent'),
                      onPressed: store.applicationActive
                          ? () => unawaited(session.consent())
                          : null,
                      child: Text(store.t('httpConfirmPlayback')),
                    ),
                  ],
                ),
              ),
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
