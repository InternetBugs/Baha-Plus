(function () {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  const expectedID = '%ANIME_ID%';
  const videoID = new URL(location.href).searchParams.get('sn');
  if (!/^\d{1,10}$/.test(expectedID) || !/^\d{1,10}$/.test(videoID || '')) return;
  const nonce = window.__bahaDocumentNonce;
  if (window.__bahaPlayerBridge?.ticket === nonce) return;
  window.__bahaPlayerBridge?.dispose();
  let timer, style, metadataSent = false, last = '', requestedQuality = 0;
  let preferences = window.__bahaDanmakuPreferences || null;
  let appliedManager = null, appliedPreferences = '';
  let cachePlayer = null, originalSourceSetter = null;
  let cacheEnabled = false, cacheRecovering = false, cacheFailed = false, cacheTimeline = null;
  const text = node => node?.textContent.replace(/\s+/g, ' ').trim() || '';
  const visible = node => !!node && node.getBoundingClientRect().height > 0 &&
    getComputedStyle(node).display !== 'none' && getComputedStyle(node).visibility !== 'hidden' &&
    Number(getComputedStyle(node).opacity) > 0;
  const post = body => bahaPostJSON(JSON.stringify({ ...body, id: expectedID, videoId: videoID }));
  const finite = value => Number.isFinite(value) ? Math.max(0, Math.min(172800, value)) : 0;
  const nativeQuality = window.__bahaCreateNativeHlsQuality?.({
    isCurrent: () => window.__bahaDocumentNonce === nonce,
    onChange: () => tick()
  });
  function qualityLevels(player) {
    const levels = player?.qualityLevels?.();
    return levels ? Array.from({ length: levels.length }, (_, i) => levels[i]) : [];
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
    let phase = 'loading';
    if (series && !matches) phase = 'error';
    else if (age) phase = 'age';
    else if (error) phase = 'error';
    else if (core?.state?.playingAd === true) phase = 'advertisement';
    else if (core?.state?.playingVideo === true &&
      String(core.state.videoSn) === videoID) phase = 'content';
    else if (root && !core) phase = 'official';
    return { root, player, media, manager: controls?.danmuManager, phase, matches };
  }
  function applyDanmaku(c) {
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
    const c = context();
    if (cacheEnabled && c.phase === 'content' && c.media?.duration > 0 && !nativeQuality?.isSwitching()) {
      cacheTimeline = {position: c.media.currentTime, rate: c.media.playbackRate,
        paused: c.media.paused, muted: c.media.muted};
    }
    if (cacheEnabled && c.matches && c.phase === 'error' && !cacheRecovering) {
      cacheEnabled = false; cacheRecovering = true; cacheFailed = true;
      const player = cachePlayer, original = originalSourceSetter;
      cachePlayer = null; originalSourceSetter = null;
      if (player && original) player.src = original;
      try { player?.error?.(null); } catch (_) {}
      const resolver = window.__bahaCacheOriginalSource;
      Promise.resolve(nativeQuality?.reload(player, c.media, cacheTimeline)).catch(() => false).finally(() => {
        if (window.__bahaCacheOriginalSource === resolver) {
          delete window.__bahaCacheOriginalSource;
          delete window.__bahaCacheBase;
        }
        cacheRecovering = false;
        if (window.__bahaDocumentNonce === nonce) tick();
      });
    }
    if (c.matches) mount(c.root);
    applyDanmaku(c);
    metadata();
    const duration = finite(c.media?.duration);
    const position = Math.min(duration, finite(c.media?.currentTime));
    let buffered = 0;
    try { if (c.media?.buffered.length) buffered = Math.min(duration, finite(c.media.buffered.end(c.media.buffered.length - 1))); } catch (_) {}
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
    const native = levels.length === 0 && !c.player?.tech?.(true)?.vhs && c.matches &&
      c.phase === 'content' ? nativeQuality?.update(c.player, c.media) : null;
    const qualities = native?.qualities ||
      [...new Set(levels.map(l => l.height))].sort((a, b) => b - a);
    const enabled = [...new Set(levels.filter(l => l.enabled === true).map(l => l.height))];
    const quality = native ? native.quality : requestedQuality > 0 && qualities.includes(requestedQuality) &&
      enabled.length === 1 && enabled[0] === requestedQuality ? requestedQuality :
      enabled.length === 1 && qualities.length > 1 ? enabled[0] : 0;
    const danmaku = c.root?.querySelector('.vjs-danmu');
    const body = {
      type: 'player-state', phase: cacheRecovering ? 'loading' : c.phase, surfaceReady: !!c.root && c.matches,
      paused: c.media?.paused !== false, ended: c.media?.ended === true,
      muted: c.media?.muted === true, buffering: !c.media || c.media.readyState < 3,
      position, duration, buffered, rate: c.media?.playbackRate || 1,
      qualities, quality,
      mediaSource: c.phase === 'content' && !c.player?.tech?.(true)?.vhs
        ? nativeQuality?.source(c.player, c.media) || null : null,
      cacheActive: cacheEnabled,
      cacheFailed,
      hasDanmaku: !!danmaku, danmaku: !!danmaku && getComputedStyle(danmaku).display !== 'none'
    };
    const serialized = JSON.stringify(body);
    if (serialized !== last) { last = serialized; post(body); }
  }
  async function command(ticket, action, value) {
    if (ticket !== nonce || window.__bahaDocumentNonce !== nonce ||
        window.__bahaMediaSuspended === true) return false;
    const c = context();
    // Only the official core can declare that ads and age checks are complete.
    if (!c.matches || !['content', 'advertisement'].includes(c.phase) ||
        !c.media || !(c.media.duration > 0)) return false;
    if (c.phase === 'advertisement' && !['play', 'pause', 'mute'].includes(action)) return false;
    try {
      if (action === 'play') await c.player.play();
      else if (action === 'pause') c.player.pause();
      else if (action === 'seek' && Number.isFinite(value)) c.player.currentTime(Math.max(0, Math.min(c.media.duration, value)));
      else if (action === 'rate' && [.5, .75, 1, 1.25, 1.5, 1.75, 2].includes(value)) c.player.playbackRate(value);
      else if (action === 'mute') c.player.muted(!c.player.muted());
      else if (action === 'quality' && Number.isInteger(value)) {
        const levels = qualityLevels(c.player);
        if (levels.length === 0 && !c.player?.tech?.(true)?.vhs) {
          if (!nativeQuality || !await nativeQuality.select(value, c.player, c.media)) return false;
        } else {
          if (value !== 0 && !levels.some(l => l.height === value)) return false;
          levels.forEach(level => { level.enabled = value === 0 || level.height === value; });
          requestedQuality = value;
        }
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
        !nativeQuality) return false;
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
    nativeQuality?.dispose();
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
  window.__bahaPlayerBridge = { ticket: nonce, command, configure, enableCache, dispose };
  tick();
  timer = setInterval(tick, 500);
})(); true;
