(function () {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  const expectedID = '%ANIME_ID%';
  const videoID = new URL(location.href).searchParams.get('sn');
  if (!/^\d{1,10}$/.test(expectedID) || !/^\d{1,10}$/.test(videoID || '')) return;
  const nonce = window.__bahaDocumentNonce;
  if (window.__bahaPlayerBridge?.ticket === nonce) return;
  window.__bahaPlayerBridge?.dispose();
  let timer, style, metadataSent = false, last = '', requestedQuality = null;
  let preferences = window.__bahaDanmakuPreferences || null;
  let appliedManager = null, appliedPreferences = '';
  let cachePlayer = null, originalSourceSetter = null;
  let cacheEnabled = false, cacheRecovering = false, cacheFailed = false, cacheTimeline = null;
  let suspendedTimeline = null, lifecycleSuspended = window.__bahaMediaSuspended === true;
  let qualityQueue = Promise.resolve(), qualityList = null;
  let lastProgress = null, stalledSince = 0, recoveryAfter = 0, recoveryCount = 0;
  let checkpointRestored = false;
  let downloadSample = null, downloadBytesPerSecond = 0;
  const text = node => node?.textContent.replace(/\s+/g, ' ').trim() || '';
  const visible = node => !!node && node.getBoundingClientRect().height > 0 &&
    getComputedStyle(node).display !== 'none' && getComputedStyle(node).visibility !== 'hidden' &&
    Number(getComputedStyle(node).opacity) > 0;
  const post = body => bahaPostJSON(JSON.stringify({ ...body, id: expectedID, videoId: videoID }));
  const finite = value => Number.isFinite(value) ? Math.max(0, Math.min(172800, value)) : 0;
  const nativeQuality = window.__bahaCreateNativeHlsQuality?.({
    isCurrent: () => window.__bahaDocumentNonce === nonce && context().contentAuthorized,
    onChange: () => tick()
  });
  function qualityLevels(player) {
    const levels = player?.qualityLevels?.();
    return levels ? Array.from({ length: levels.length }, (_, i) => levels[i]) : [];
  }
  function downloadSpeed(c) {
    const vhs = c.player?.tech?.(true)?.vhs;
    const bytes = vhs?.stats?.mediaBytesTransferred;
    const now = window.performance?.now?.() ?? Date.now();
    if (requiresNative() || !Number.isFinite(bytes) || bytes < 0) {
      downloadSample = null; downloadBytesPerSecond = 0; return 0;
    }
    if (!downloadSample || downloadSample.vhs !== vhs || bytes < downloadSample.bytes ||
        now < downloadSample.time) {
      downloadSample = {vhs, bytes, time: now}; downloadBytesPerSecond = 0;
    } else if (now - downloadSample.time >= 1000) {
      downloadBytesPerSecond = Math.min(1e12, (bytes - downloadSample.bytes) * 1000 / (now - downloadSample.time));
      downloadSample = {vhs, bytes, time: now};
    }
    return downloadBytesPerSecond;
  }
  const nativeHls = c => !c.player?.tech?.(true)?.vhs && !!nativeQuality?.source(c.player, c.media);
  const requiresNative = () => ['android-exoplayer', 'ios-avplayer', 'windows-mpv'].includes(window.__bahaNativeBackend);
  const sourceQuality = c => nativeHls(c) || nativeQuality?.hasInitialSelection(c.player, c.media);
  const snapshot = c => nativeQuality?.timeline() || {
    position: c.media.currentTime, rate: c.media.playbackRate,
    paused: c.media.paused, muted: c.media.muted
  };
  function suspend() {
    if (nativePlayback?.active) {
      lifecycleSuspended = true;
      window.__bahaMediaSuspended = true;
      return;
    }
    if (requiresNative()) nativePlayback?.hold(true);
    const c = context();
    if (!lifecycleSuspended && c.matches && c.media && c.media.duration > 0) {
      suspendedTimeline = {...snapshot(c), paused: true};
    }
    lifecycleSuspended = true;
    window.__bahaMediaSuspended = true;
    nativeQuality?.suspend();
    if (window.__bahaPlaybackCheckpoint?.videoId === videoID) window.__bahaPlaybackCheckpoint.paused = true;
    c.player?.pause();
    c.media?.pause?.();
    lastProgress = null;
  }
  function restoreSuspended(c) {
    if (!suspendedTimeline || !c.matches || !c.media || !(c.media.duration > 0) ||
        c.media.readyState < 1 || nativeQuality?.isSwitching()) return;
    c.player.pause();
    const position = Math.min(suspendedTimeline.position, c.media.duration);
    if (!suspendedTimeline.positioned || Math.abs(c.media.currentTime - position) > .5) {
      suspendedTimeline.positioned = true;
      c.player.currentTime(position);
    }
    c.player.playbackRate(suspendedTimeline.rate);
    c.player.muted(suspendedTimeline.muted);
    if (c.media.seeking || Math.abs(c.media.currentTime - position) > .5) return;
    suspendedTimeline = null;
  }
  function resume() {
    lifecycleSuspended = false;
    window.__bahaMediaSuspended = false;
    if (nativePlayback?.active) return;
    restoreSuspended(context());
    lastProgress = null;
    tick();
  }
  function visibilityChanged() {
    if (document.visibilityState === 'hidden' && window.__bahaMediaSuspended === true) suspend();
    // Flutter owns foreground activation; visibility alone cannot override
    // an application that is still in the background.
  }
  function restoreCheckpoint(c) {
    const saved = window.__bahaPlaybackCheckpoint;
    if (!saved || saved.videoId !== videoID || c.phase !== 'content' ||
        !c.media || !(c.media.duration > 0) || c.media.readyState < 1 ||
        nativeQuality?.isSwitching()) return false;
    if (!Number.isFinite(saved.position) || saved.position < 0 || saved.position > 172800 ||
        ![.5, .75, 1, 1.25, 1.5, 1.75, 2].includes(saved.rate) ||
        typeof saved.paused !== 'boolean' || typeof saved.muted !== 'boolean') {
      window.__bahaPlaybackCheckpoint = null; return false;
    }
    const target = Math.min(saved.position, c.media.duration);
    if (!saved.positioned) {
      saved.positioned = true;
      c.player.currentTime(target);
    }
    c.player.playbackRate(saved.rate);
    c.player.muted(saved.muted);
    if (saved.paused || window.__bahaMediaSuspended === true) c.player.pause();
    if (c.media.seeking || Math.abs(c.media.currentTime - target) > 1) return true;
    checkpointRestored = true;
    window.__bahaPlaybackCheckpoint = null;
    return false;
  }
  function diagnostics() {
    const c = context(), media = c.media;
    const clock = nativePlayback?.active ? window.__bahaNativeTimeline : null;
    let start = 0, end = 0, ranges = 0;
    try {
      ranges = media?.buffered.length || 0;
      if (ranges) {start = media.buffered.start(0); end = media.buffered.end(ranges - 1);}
    } catch (_) {}
    if (clock) {start = clock.position; end = clock.buffered; ranges = end > start ? 1 : 0;}
    const canvases = [...document.querySelectorAll('canvas')];
    const heap = window.performance?.memory;
    return {
      phase: c.phase, backend: nativePlayback?.active ? nativePlayback.backend :
        c.player?.tech?.(true)?.vhs ? 'vhs' : 'native-hls',
      position: finite(clock?.position ?? media?.currentTime), duration: finite(clock?.duration ?? media?.duration),
      paused: (clock || media)?.paused !== false, readyState: clock ? 4 : media?.readyState ?? 0,
      videoWidth: clock?.videoWidth || media?.videoWidth || 0,
      videoHeight: clock?.videoHeight || media?.videoHeight || 0,
      bufferRanges: ranges, bufferBehind: finite((clock?.position || media?.currentTime || 0) - start),
      bufferAhead: finite(end - (clock?.position || media?.currentTime || 0)),
      domNodes: document.querySelectorAll('*').length,
      danmakuNodes: c.root?.querySelector('.vjs-danmu')?.querySelectorAll('*').length || 0,
      canvases: canvases.length, canvasPixels: canvases.reduce((sum, canvas) => sum + canvas.width * canvas.height, 0),
      iframes: document.querySelectorAll('iframe').length,
      videos: document.querySelectorAll('video').length,
      heapUsed: Number.isFinite(heap?.usedJSHeapSize) ? heap.usedJSHeapSize : null,
      cacheActive: cacheEnabled, checkpointRestored
    };
  }
  function applyQuality(c, value) {
    const levels = qualityLevels(c.player);
    if (value !== 0 && !levels.some(level => level.height === value)) return false;
    // Keep the official selector's saved choice in sync: animePlayer can
    // otherwise restore its old local choice after rebuilding its controls.
    try { window.localStorage?.setItem('ANIME_quality',
      value === 0 ? c.player.localize?.('Auto') || 'Auto' : String(value)); } catch (_) {}
    const selector = c.player.controlBar?.getChildById?.('controlBarR')?.getChildById?.('resButton');
    selector?.updateQuality?.(value === 0 ? c.player.localize?.('Auto') || 'Auto' : value);
    // Enable the target before disabling the old rendition, so VHS never
    // observes an intermediate state with every rendition disabled.
    levels.filter(level => value === 0 || level.height === value).forEach(level => { level.enabled = true; });
    levels.filter(level => value !== 0 && level.height !== value).forEach(level => { level.enabled = false; });
    qualityList = levels[0];
    return levels.length > 0 && levels.every(level => level.enabled === (value === 0 || level.height === value));
  }
  async function recover(c) {
    if (cacheRecovering || nativeQuality?.isSwitching() || !nativeQuality ||
        !c.matches || !c.contentAuthorized || !nativeQuality.source(c.player, c.media)) return;
    const timeline = suspendedTimeline || cacheTimeline || (c.media && snapshot(c));
    if (!timeline) return;
    recoveryAfter = Date.now() + 60000;
    recoveryCount++;
    cacheRecovering = true;
    const resolver = window.__bahaCacheOriginalSource;
    if (cacheEnabled) {
      cacheEnabled = false; cacheFailed = true;
      if (cachePlayer && originalSourceSetter) cachePlayer.src = originalSourceSetter;
      cachePlayer = null; originalSourceSetter = null;
    }
    try {
      c.player.error?.(null);
      await nativeQuality.reload(c.player, c.media, timeline);
    } catch (_) {}
    finally {
      if (resolver && window.__bahaCacheOriginalSource === resolver) {
        delete window.__bahaCacheOriginalSource;
        delete window.__bahaCacheBase;
      }
      cacheRecovering = false;
      qualityList = null; lastProgress = null;
      if (window.__bahaDocumentNonce === nonce) tick();
    }
  }
  function context() {
    const root = document.querySelector('#video-container');
    const series = document.querySelector('.anime_name button[onclick*="toggleGather"]')
      ?.getAttribute('onclick')?.match(/toggleGather\(\d+,\s*(\d+)/)?.[1];
    const matches = series === expectedID;
    const player = root?.querySelector('#ani_video, video-js, .video-js')?.player;
    const core = player?.usingPlugin?.('m3u8') ? player.m3u8() : null;
    const controls = player?.usingPlugin?.('animePlayer') ? player.animePlayer() : null;
    const media = root?.querySelector('video');
    const age = visible(root?.querySelector('.ncc-choosebar'));
    const error = !!media?.error || !!player?.error?.();
    const contentAuthorized = core?.state?.playingVideo === true &&
      core.state.playingAd !== true && String(core.state.videoSn) === videoID;
    let phase = 'loading';
    if (series && !matches) phase = 'error';
    else if (age) phase = 'age';
    else if (error) phase = 'error';
    else if (core?.state?.playingAd === true) phase = 'advertisement';
    else if (contentAuthorized) phase = 'content';
    else if (root && !core) phase = 'official';
    return { root, player, media, manager: controls?.danmuManager, phase, matches, contentAuthorized };
  }
  function applyDanmaku(c) {
    if (nativePlayback?.active || requiresNative()) return;
    if (!preferences || c.phase !== 'content') {
      appliedManager = null;
      return;
    }
    const layer = c.root?.querySelector('.vjs-danmu');
    const manager = c.manager;
    if (layer) layer.style.display = preferences.enabled ? '' : 'none';
    const key = JSON.stringify(preferences);
    if (!manager || (manager === appliedManager && key === appliedPreferences)) return;
    manager.setDanmuOpacityRate?.(preferences.opacity);
    manager.setDanmuSizeRate?.(preferences.scale);
    for (const mode of ['rolling', 'top', 'bottom']) {
      manager.setDanmuModeAllow?.(mode, preferences[mode]);
    }
    manager.setDanmuProcess?.(preferences.enabled);
    manager.cleanAll?.();
    appliedManager = manager; appliedPreferences = key;
  }
  function configure(ticket, value) {
    if (ticket !== nonce || window.__bahaDocumentNonce !== nonce ||
        !value || !Number.isFinite(value.opacity) || value.opacity < .1 || value.opacity > 1 ||
        !Number.isFinite(value.scale) || value.scale < .5 || value.scale > 1.5 ||
        ['enabled', 'rolling', 'top', 'bottom'].some(key => typeof value[key] !== 'boolean')) return false;
    preferences = { enabled: value.enabled, opacity: value.opacity, scale: value.scale,
      rolling: value.rolling, top: value.top, bottom: value.bottom };
    window.__bahaDanmakuPreferences = preferences;
    tick(); return true;
  }
  function mount(root) {
    if (!root || style) return;
    style = document.createElement('style');
    style.id = 'baha-player-layout';
    style.textContent = `
      html,body{margin:0!important;padding:0!important;width:100%!important;height:100%!important;overflow:hidden!important;background:#000!important}
      body>*{visibility:hidden!important}
      #video-container{visibility:visible!important;position:fixed!important;inset:0!important;width:100%!important;height:100%!important;margin:0!important;padding:0!important;z-index:2147483000!important;background:#000!important;overflow:hidden!important}
      #video-container>.video-js,#video-container>video-js{position:absolute!important;inset:0!important;width:100%!important;height:100%!important;padding:0!important}
      #video-container video{width:100%!important;height:100%!important;object-fit:contain!important}
      #video-container .ncc-choosearea{max-width:94%!important}
      #video-container .ncc-choosearea>img{max-width:20vw!important;max-height:28vh!important;object-fit:contain}
      #video-container .ncc-choosebar{font-size:12px!important}
      #video-container .ncc-choose-btn button{font-size:14px!important;min-height:30px!important;padding:4px 12px!important}
      .baha-native-controls #video-container .vjs-control-bar,
      .baha-native-controls #video-container .vjs-big-play-button{opacity:0!important;pointer-events:none!important}
      .baha-native-controls #video-container video::-webkit-media-controls{display:none!important}
      .baha-native-controls #video-container .vast-skip-button{bottom:108px!important}
      dialog[open],dialog[open] *,.dialogify,.dialogify *,.dialog-overlay{visibility:visible!important}
    `;
    document.head.append(style);
  }
  function metadata() {
    if (metadataSent) return;
    const button = document.querySelector('.anime_name button[onclick*="toggleGather"]');
    const id = button?.getAttribute('onclick')?.match(/toggleGather\(\d+,\s*(\d+)/)?.[1];
    if (id !== expectedID) return;
    const intro = document.querySelector('.data-intro')?.cloneNode(true);
    intro?.querySelectorAll('.link,.link-button,.material-icons,button,script,style').forEach(n => n.remove());
    const episodes = new Map();
    document.querySelectorAll('.season a[href], a[href*="animeVideo.php?sn="]').forEach(a => {
      const uri = new URL(a.getAttribute('href'), location.href);
      const id = uri.searchParams.get('sn'), label = text(a);
      const declared = a.getAttribute('data-ani-video-sn');
      if (uri.origin === location.origin && uri.pathname === '/animeVideo.php' &&
          /^\d{1,10}$/.test(id || '') && (!declared || declared === id) &&
          label.length > 0 && label.length <= 100 &&
          (a.closest('.season') || /^(?:第\s*)?\d+(?:\.\d+)?(?:\s*集)?$/.test(label))) {
        if (!episodes.has(id)) episodes.set(id, { id, label });
      }
    });
    const img = document.querySelector('.data-img');
    const score = Number(text(document.querySelector('#acg_review .score-overall-number')));
    const count = Number((text(document.querySelector('#acg_review .score-overall-people'))
      .match(/[0-9,]+/) || ['0'])[0].replaceAll(',', ''));
    let rating;
    const source = [...document.querySelectorAll('script')]
      .map(script => script.textContent || '').find(code => code.includes('new Bahamut.AcgReview'));
    const match = source?.match(/new Bahamut\.AcgReview\([^,]+,\s*(\d+),\s*(\{[^}]+\})/);
    if (match && Number.isFinite(score) && score >= 0 && score <= 5 &&
        Number.isInteger(count) && count >= 0) {
      try {
        const values = JSON.parse(match[2]);
        const distribution = [1, 2, 3, 4, 5].map(star => Number(values[String(star)] || 0));
        if (distribution.every(value => Number.isInteger(value) && value >= 0) &&
            distribution.reduce((sum, value) => sum + value, 0) <= count) {
          rating = { value: score, count, distribution };
        }
      } catch (_) {}
    }
    const detail = {
      title: text(document.querySelector('.anime_name h1')).replace(/\s*\[[^\]]+\]\s*$/, ''),
      description: text(intro).split(/[＜<](?:製作團隊|制作团队|STAFF|CAST)[＞>]/i)[0].trim(),
      poster: img?.getAttribute('data-src') || img?.getAttribute('src'),
      ...(rating ? { rating } : {}),
      episodes: [...episodes.values()],
      metadata: [...document.querySelectorAll('.type-list>li')].map(li => ({
        label: text(li.querySelector('.title')),
        value: text(li.querySelector('.content')) || [...li.querySelectorAll('ul>li')].map(text).filter(Boolean).join('、')
      })).filter(m => m.label && m.value)
    };
    if (!detail.title) return;
    metadataSent = true;
    post({ type: 'player-detail', detail });
  }
  function tick() {
    if (window.__bahaDocumentNonce !== nonce) { dispose(); return; }
    if (nativePlayback?.active) return;
    const c = context();
    // A native host never silently continues a full episode on HTML media,
    // including while preparing or after a failed AVPlayer initialization.
    if (requiresNative() && c.phase === 'content') nativePlayback?.hold();
    const restoringCheckpoint = restoreCheckpoint(c);
    if (!lifecycleSuspended) restoreSuspended(c);
    const now = Date.now();
    if (!requiresNative() && !lifecycleSuspended && !cacheRecovering && !nativeQuality?.isSwitching() &&
        c.phase === 'content' && c.media?.duration > 0) {
      cacheTimeline = snapshot(c);
      const frames = c.media.getVideoPlaybackQuality?.()?.totalVideoFrames ?? c.media.webkitDecodedFrameCount;
      const progress = {position: c.media.currentTime, frames};
      if (lastProgress && progress.position > lastProgress.position &&
          (!(frames > 0) || frames > lastProgress.frames) && now >= recoveryAfter) recoveryCount = 0;
      if (c.media.paused || c.media.ended || c.media.seeking || !lastProgress ||
          (progress.position !== lastProgress.position &&
            (!(frames > 0) || frames !== lastProgress.frames))) stalledSince = now;
      lastProgress = progress;
      if (!c.media.paused && !c.media.ended && !c.media.seeking &&
          now - stalledSince >= 20000 && now >= recoveryAfter && recoveryCount < 2) {
        void recover(c);
      }
    } else lastProgress = null;
    const mediaError = c.media?.error?.code;
    const playerError = c.player?.error?.()?.code;
    if (!requiresNative() && !lifecycleSuspended && c.matches && c.phase === 'error' &&
        [2, 3, 4].includes(mediaError || playerError) && !(playerError >= 1000) &&
        now >= recoveryAfter && recoveryCount < 2) {
      void recover(c);
    }
    if (c.matches) mount(c.root);
    applyDanmaku(c);
    metadata();
    const duration = finite(c.media?.duration);
    const position = Math.min(duration, finite(suspendedTimeline?.position ?? c.media?.currentTime));
    const bufferedRanges = [];
    try {
      const ranges = c.media?.buffered;
      for (let i = 0; i < (ranges?.length || 0); i++) {
        const start = Math.min(duration, finite(ranges.start(i)));
        const end = Math.min(duration, finite(ranges.end(i)));
        if (end > start) bufferedRanges.push([start, end]);
      }
    } catch (_) {}
    const buffered = bufferedRanges.reduce((end, range) => Math.max(end, range[1]), 0);
    // Preserve official prompts until there is a timeline native controls can
    // actually operate. This also keeps the official error UI accessible.
    const nativeControls = c.matches && !!c.root && duration > 0 &&
      ['content', 'advertisement'].includes(c.phase);
    document.documentElement.classList.toggle('baha-native-controls', nativeControls);
    c.root?.querySelectorAll('.vjs-control-bar,.vjs-big-play-button').forEach(node => {
      node.setAttribute('aria-hidden', String(nativeControls));
      node.inert = nativeControls;
    });
    const levels = qualityLevels(c.player).filter(l => Number.isInteger(l.height) && l.height >= 144 && l.height <= 4320);
    const native = !requiresNative() && sourceQuality(c) && c.matches &&
      c.phase === 'content' ? nativeQuality?.update(c.player, c.media) : null;
    if (!requiresNative() && !native && requestedQuality !== null && c.phase === 'content' && levels[0] !== qualityList &&
        (requestedQuality === 0 || levels.some(level => level.height === requestedQuality))) applyQuality(c, requestedQuality);
    const qualities = native?.qualities ||
      [...new Set(levels.map(l => l.height))].sort((a, b) => b - a);
    const enabled = [...new Set(levels.filter(l => l.enabled === true).map(l => l.height))];
    const quality = native ? native.quality : requestedQuality > 0 && qualities.includes(requestedQuality) &&
      enabled.length === 1 && enabled[0] === requestedQuality ? requestedQuality :
      enabled.length === 1 && qualities.length > 1 ? enabled[0] : 0;
    const danmaku = c.root?.querySelector('.vjs-danmu');
    const body = {
      type: 'player-state', phase: cacheRecovering || restoringCheckpoint ? 'loading' : c.phase, surfaceReady: !!c.root && c.matches,
      paused: c.media?.paused !== false, ended: c.media?.ended === true,
      muted: c.media?.muted === true, buffering: !c.media || c.media.readyState < 3,
      position, duration, buffered, bufferedRanges, rate: c.media?.playbackRate || 1,
      downloadBytesPerSecond: downloadSpeed(c),
      qualities, quality,
      mediaSource: c.phase === 'content' && !c.player?.tech?.(true)?.vhs
        ? nativeQuality?.source(c.player, c.media) || null : null,
      mediaSources: nativeQuality?.hasInitialSelection(c.player, c.media) ? nativeQuality.sources() : [],
      cacheActive: cacheEnabled,
      cacheFailed,
      checkpointRestored,
      recoverable: c.phase === 'error' && [2, 3, 4].includes(mediaError || playerError) &&
        !(playerError >= 1000),
      hasDanmaku: !!danmaku, danmaku: !!danmaku && getComputedStyle(danmaku).display !== 'none'
    };
    const serialized = JSON.stringify(body);
    if (serialized !== last || (requiresNative() && c.phase === 'content')) {
      last = serialized; post(body);
    }
  }
  async function command(ticket, action, value) {
    if (ticket !== nonce || window.__bahaDocumentNonce !== nonce ||
        window.__bahaMediaSuspended === true || nativePlayback?.active) return false;
    if (requiresNative() && context().phase === 'content') {
      if (action === 'pause') return nativePlayback?.hold(true) === true;
      return false;
    }
    if (action === 'quality') {
      const run = async () => {
        const c = context();
        if (ticket !== nonce || window.__bahaDocumentNonce !== nonce ||
            window.__bahaMediaSuspended === true || !c.matches ||
            c.phase !== 'content' || !c.media || !(c.media.duration > 0) ||
            suspendedTimeline || !Number.isInteger(value)) return false;
        const accepted = sourceQuality(c) ? !!await nativeQuality.select(value, c.player, c.media) : applyQuality(c, value);
        if (accepted) {
          requestedQuality = value;
          window.__bahaPreferredQuality = value;
        }
        tick(); return accepted;
      };
      const pending = qualityQueue.then(run, run);
      qualityQueue = pending.catch(() => false);
      return pending;
    }
    const c = context();
    // Only the official core can declare that ads and age checks are complete.
    if (!c.matches || !['content', 'advertisement'].includes(c.phase) ||
        !c.media || (!(c.media.duration > 0) && action !== 'pause')) return false;
    if (c.phase === 'advertisement' && !['play', 'pause', 'mute'].includes(action)) return false;
    try {
      if (action === 'play') {
        if (window.__bahaPlaybackCheckpoint?.videoId === videoID) window.__bahaPlaybackCheckpoint.paused = false;
        restoreSuspended(c);
        if (suspendedTimeline) return false;
        await c.player.play();
      }
      else if (action === 'pause') {
        if (window.__bahaPlaybackCheckpoint?.videoId === videoID) window.__bahaPlaybackCheckpoint.paused = true;
        c.player.pause(); nativeQuality?.suspend();
      }
      else if (action === 'seek' && Number.isFinite(value)) c.player.currentTime(Math.max(0, Math.min(c.media.duration, value)));
      else if (action === 'rate' && [.5, .75, 1, 1.25, 1.5, 1.75, 2].includes(value)) c.player.playbackRate(value);
      else if (action === 'mute') {
        c.player.muted(!c.player.muted());
        if (window.__bahaPlaybackCheckpoint?.videoId === videoID) window.__bahaPlaybackCheckpoint.muted = c.media.muted;
      }
      else if (action === 'danmaku' && (value === 0 || value === 1)) {
        const layer = c.root.querySelector('.vjs-danmu');
        if (!layer) return false;
        layer.style.display = value === 0 ? 'none' : '';
        if (preferences) preferences.enabled = value === 1;
      }
      else return false;
      tick(); return true;
    } catch (_) { return false; }
  }
  async function enableCache(ticket, source, base) {
    if (ticket !== nonce || window.__bahaDocumentNonce !== nonce || cachePlayer ||
        window.__bahaNativeBackend || !nativeQuality) return false;
    if (nativeQuality.isSwitching()) return null;
    const c = context();
    if (!c.matches || c.phase !== 'content' || !c.media || !(c.media.duration > 0) ||
        c.player?.tech?.(true)?.vhs) return false;
    if (nativeQuality.source(c.player, c.media) !== source) return null;
    let origin;
    try {
      origin = new URL(base);
      if (origin.protocol !== 'http:' || origin.hostname !== 'localhost' ||
          Number(origin.port) < 1024 || origin.username || origin.password ||
          origin.search || origin.hash ||
          !/^\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\/$/i.test(origin.pathname)) return false;
    } catch (_) { return false; }
    function upstream(raw) {
      try {
        const value = new URL(raw);
        if (value.origin === origin.origin && value.pathname.startsWith(origin.pathname)) {
          return value.searchParams.get('u') || raw;
        }
      } catch (_) {}
      return raw;
    }
    function proxy(raw) {
      try {
        const value = new URL(raw);
        if (value.origin !== 'https://bahamut.akamaized.net' || value.username || value.password ||
            value.hash || !/\.m3u8$/i.test(value.pathname) || !nativeQuality.owns(value.href)) return raw;
        const local = new URL('media.m3u8', origin);
        local.searchParams.set('u', value.href);
        return local.href;
      } catch (_) { return raw; }
    }
    const snapshot = {position: c.media.currentTime, rate: c.media.playbackRate,
      paused: c.media.paused, muted: c.media.muted};
    cacheTimeline = snapshot;
    cachePlayer = c.player;
    originalSourceSetter = c.player.src;
    const original = originalSourceSetter;
    const setter = function (value) {
      if (arguments.length === 0) return original.call(this);
      const convert = item => typeof item === 'string' ? proxy(item) :
        item && typeof item.src === 'string' ? {...item, src: proxy(item.src)} : item;
      return original.call(this, Array.isArray(value) ? value.map(convert) : convert(value));
    };
    window.__bahaCacheOriginalSource = upstream;
    window.__bahaCacheBase = base;
    c.player.src = setter;
    if (await nativeQuality.reload(c.player, c.media, snapshot)) {
      cacheEnabled = true; tick(); return true;
    }
    if (c.player.src === setter) c.player.src = original;
    // A local gateway failure restores the official authorized source and the
    // previous timeline; it never changes the official ad/entitlement state.
    if (window.__bahaDocumentNonce === nonce) {
      await nativeQuality.reload(c.player, c.media, snapshot);
    }
    if (window.__bahaCacheOriginalSource === upstream) {
      delete window.__bahaCacheOriginalSource;
      delete window.__bahaCacheBase;
    }
    cachePlayer = null; originalSourceSetter = null;
    return false;
  }
  function dispose() {
    clearInterval(timer);
    nativePlayback?.dispose();
    nativeQuality?.dispose();
    document.removeEventListener('visibilitychange', visibilityChanged);
    releaseMediaSession();
    cacheEnabled = false;
    if (cachePlayer && originalSourceSetter) cachePlayer.src = originalSourceSetter;
    delete window.__bahaCacheOriginalSource;
    delete window.__bahaCacheBase;
    style?.remove();
    document.documentElement.classList.remove('baha-native-controls');
    document.querySelectorAll('#video-container .vjs-control-bar,#video-container .vjs-big-play-button').forEach(node => {
      node.removeAttribute('aria-hidden'); node.inert = false;
    });
    if (window.__bahaPlayerBridge?.ticket === nonce) delete window.__bahaPlayerBridge;
  }
  const nativePlayback = window.__bahaCreateNativePlayback?.({
    context, isCurrent: () => window.__bahaDocumentNonce === nonce
  });
  window.__bahaPlayerBridge = { ticket: nonce, command, configure, enableCache, suspend, resume, diagnostics, dispose,
    prepareNative: () => !cachePlayer && !cacheRecovering && !suspendedTimeline &&
      !nativeQuality?.isSwitching() ? nativePlayback?.prepare() : null,
    commitNative: () => {
      if (cachePlayer || cacheRecovering || suspendedTimeline || nativeQuality?.isSwitching()) return null;
      const timeline = nativePlayback?.commit() || null;
      if (timeline) {
        nativeQuality?.dispose();
        clearInterval(timer);
        releaseMediaSession();
      }
      return timeline;
    },
    failNative: () => {
      if (!requiresNative() || nativePlayback?.active) return false;
      nativePlayback?.hold(true);
      clearInterval(timer);
      releaseMediaSession();
      return true;
    },
    syncNative: value => nativePlayback?.sync(value) === true,
    nativeStatus: () => nativePlayback?.status() || 'unavailable',
    nativeDanmaku: () => nativePlayback?.danmaku() || [],
    acknowledgeNativeDanmaku: ids => nativePlayback?.acknowledgeDanmaku(ids) === true };
  document.addEventListener('visibilitychange', visibilityChanged);
  function releaseMediaSession() {
    try {
      for (const action of ['play', 'pause', 'stop', 'seekbackward', 'seekforward',
        'seekto', 'previoustrack', 'nexttrack']) {
        try { navigator.mediaSession?.setActionHandler(action, null); } catch (_) {}
      }
      if (navigator.mediaSession) {
        navigator.mediaSession.playbackState = 'none';
        navigator.mediaSession.metadata = null;
      }
    } catch (_) {}
  }
  try {
    navigator.mediaSession?.setActionHandler('play', () => command(nonce, 'play'));
    navigator.mediaSession?.setActionHandler('pause', () => command(nonce, 'pause'));
  } catch (_) {}
  tick();
  timer = setInterval(tick, 500);
})(); true;
