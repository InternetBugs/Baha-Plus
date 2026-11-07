(function () {
  // Exiting playback must release the media pipeline. Pausing alone leaves
  // WebKit's Now Playing session attached to this persistent document.
  try { window.__bahaPlayerBridge?.dispose(); } catch (_) {}
  document.querySelectorAll('video,audio').forEach(media => {
    try { media.pause(); } catch (_) {}
    media.removeAttribute('autoplay');
    try { media.srcObject = null; } catch (_) {}
    media.removeAttribute('src');
    media.querySelectorAll('source').forEach(source => source.removeAttribute('src'));
    try { media.load(); } catch (_) {}
  });
  // Stop the official player's timers and source recovery after unloading.
  try { document.querySelector('#ani_video')?.player?.dispose?.(); } catch (_) {}
  try {
    const session = navigator.mediaSession;
    if (!session) return;
    try { session.playbackState = 'none'; } catch (_) {}
    try { session.metadata = null; } catch (_) {}
    try { session.setPositionState?.(); } catch (_) {}
    for (const action of [
      'play', 'pause', 'stop', 'seekbackward', 'seekforward', 'seekto',
      'previoustrack', 'nexttrack', 'skipad'
    ]) {
      try { session.setActionHandler(action, null); } catch (_) {}
    }
  } catch (_) {}
})();
