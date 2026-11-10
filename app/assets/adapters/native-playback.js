(function () {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  // The mobile host explicitly selects its backend. The document still owns
  // entitlement, ads, device locks, CSRF and the official progress callbacks.
  window.__bahaCreateNativePlayback = function ({ context, isCurrent }) {
    const backend = window.__bahaNativeBackend;
    let active = false, disposed = false, prepared = null, clock = null, held = null;
    let player = null, manager = null, media = null, heldMedia = null, original = new Map();
    const live = () => !disposed && isCurrent();
    function source(raw) {
      try {
        const url = new URL(raw);
        return url.origin === 'https://bahamut.akamaized.net' &&
          !url.username && !url.password && !url.hash &&
          /\.m3u8$/i.test(url.pathname) && url.href.length <= 4096 ? url.href : null;
      } catch (_) { return null; }
    }
    function authorized(c) {
      return live() && c.matches && c.contentAuthorized &&
        c.phase === 'content' && c.player && c.media && !c.player.isDisposed?.();
    }
    function hold(paused = false) {
      const c = context();
      if (!['android-exoplayer', 'ios-avplayer', 'windows-mpv'].includes(backend) ||
          active || !authorized(c) || !(c.media.duration > 0)) return false;
      const saved = window.__bahaPlaybackCheckpoint;
      const restoring = saved?.videoId === new URL(location.href).searchParams.get('sn') &&
        typeof saved.paused === 'boolean';
      held ??= {position: c.media.currentTime, duration: c.media.duration,
        paused: restoring ? saved.paused : c.media.paused,
        muted: c.media.muted, rate: c.media.playbackRate};
      if (heldMedia !== c.media) {
        heldMedia?.removeEventListener('play', preventWebContent);
        heldMedia = c.media;
        heldMedia.addEventListener('play', preventWebContent);
      }
      if (paused) held.paused = true;
      if (!c.media.paused) { c.player.pause(); c.media.pause?.(); }
      return true;
    }
    function preventWebContent() {
      if (!active && live()) hold();
    }
    async function prepare() {
      const c = context();
      if (!['android-exoplayer', 'ios-avplayer', 'windows-mpv'].includes(backend) || !authorized(c) ||
          !(c.media.duration > 0)) return null;
      const current = source(c.player.currentSource?.()?.src || c.media.currentSrc);
      if (!current) return null;
      const seed = window.__bahaInitialHls;
      let master = current, entries = [];
      if (seed?.videoId === new URL(location.href).searchParams.get('sn') &&
          source(seed.master) && source(seed.source) === current &&
          Array.isArray(seed.variants)) {
        master = seed.master; entries = seed.variants;
      } else {
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), 10000);
        try {
          const response = await fetch(master, {credentials: 'omit', signal: abort.signal});
          if (!response.ok || !source(response.url)) return null;
          const text = await response.text();
          if (text.length > 250000) return null;
          entries = [...(window.__bahaParseHlsVariants?.(text, response.url) || [])];
        } finally { clearTimeout(timer); }
      }
      if (!authorized(context()) || !source(master) || entries.length > 20) return null;
      const variants = entries.filter(([height, url]) =>
        Number.isInteger(height) && height >= 144 && height <= 4320 && source(url))
        .map(([height, url]) => ({height, url}));
      prepared = {master, variants, position: c.media.currentTime, duration: c.media.duration,
        paused: held?.paused ?? c.media.paused, muted: c.media.muted, rate: c.media.playbackRate};
      return prepared;
    }
    function replace(name, getter) {
      original.set(name, player[name]);
      player[name] = getter;
    }
    function commit() {
      const c = context();
      if (active) return true;
      if (!prepared || !authorized(c)) return false;
      player = c.player; manager = c.manager; media = c.media;
      const handoff = {...prepared, position: media.currentTime, duration: media.duration,
        paused: held?.paused ?? media.paused, rate: media.playbackRate, muted: media.muted};
      // The official player is paused before its clock is delegated, so there
      // can never be two active audio/video pipelines.
      player.pause(); media.pause();
      manager?.setDanmuProcess?.(false);
      manager?.cleanAll?.();
      const tech = player.tech?.(true);
      try { tech?.vhs?.dispose?.(); } catch (_) {}
      media.removeAttribute('src');
      media.querySelectorAll('source').forEach(node => node.removeAttribute('src'));
      try { media.load(); } catch (_) {}
      clock = {...handoff, paused: true,
        buffered: 0, seeking: false, ended: false};
      for (const [name, key] of [
        ['currentTime', 'position'], ['duration', 'duration'], ['paused', 'paused'],
        ['playbackRate', 'rate'], ['muted', 'muted'], ['seeking', 'seeking'], ['ended', 'ended']
      ]) replace(name, () => clock[key]);
      // Web UI commands cannot restart the unloaded HTML video. Native
      // controls are routed to the platform player by the host instead.
      replace('play', () => Promise.resolve());
      replace('pause', () => {});
      replace('readyState', () => 4);
      active = true;
      const layer = c.root?.querySelector('.vjs-danmu');
      if (layer) { layer.replaceChildren(); layer.style.display = 'none'; }
      // Drop the rest of the visual document after its metadata has been
      // projected. Keep official globals/player callbacks for account policy.
      document.querySelectorAll('iframe').forEach(node => node.remove());
      // Official policy errors are displayed through the .video container.
      // Retain that small wrapper so a later device/account rejection still
      // reaches the official error/dispose path instead of throwing on null.
      const retained = [c.root.closest('.video') || c.root];
      for (const selector of ['.anime_name', '.user-info', '.btn-logout']) {
        const node = document.querySelector(selector);
        if (node && !c.root.contains(node)) {
          node.style.display = 'none';
          retained.push(node);
        }
      }
      document.body.replaceChildren(...retained);
      window.__bahaNativeTimeline = clock;
      return handoff;
    }
    function status() {
      if (!active || !live()) return 'unavailable';
      const c = context();
      if (!c.matches || !c.contentAuthorized || player?.isDisposed?.() ||
          player?.error?.()) return 'denied';
      return 'ok';
    }
    function sync(value) {
      if (!active || !live() || !value || player.isDisposed?.()) return false;
      const c = context();
      if (!c.matches || !c.contentAuthorized || player.error?.()) return false;
      const old = clock;
      if (!Number.isFinite(value.position) || !Number.isFinite(value.duration) ||
          value.position < 0 || value.duration <= 0 || value.duration > 172800 ||
          value.position > value.duration + 1 || typeof value.paused !== 'boolean') return false;
      clock = {...old, ...value};
      window.__bahaNativeTimeline = clock;
      // Feed real native positions through the site's existing watch-time,
      // device-lock and breakpoint handlers. Never extrapolate wall time.
      if (old.paused !== clock.paused) player.trigger(clock.paused ? 'pause' : 'play');
      player.trigger('timeupdate');
      return !player.isDisposed?.() && !player.error?.();
    }
    function danmaku() {
      const c = context();
      const selected = manager || c.manager;
      if (!live() || !c.contentAuthorized || !selected?.danmuList) return [];
      const items = [], seen = new Set();
      for (const bucket of Object.values(selected.danmuList)) {
        if (!Array.isArray(bucket)) continue;
        for (const item of bucket) {
          const id = String(item.sn || ''), time = Number(item.time) / 1000;
          if (!/^\d{1,20}$/.test(id) || seen.has(id) || !Number.isFinite(time) ||
              time < 0 || time > 172800 || !['rolling', 'top', 'bottom'].includes(item.mode)) continue;
          const span = document.createElement('span');
          span.innerHTML = String(item.text || '');
          const text = span.textContent.replace(/\s+/g, ' ').trim();
          if (!text || text.length > 500) continue;
          items.push({id, time, text, mode: item.mode,
            color: /^#[0-9a-f]{6}$/i.test(item.color) ? item.color : '#FFFFFF',
            size: Math.max(12, Math.min(40, Number(item.size) || 16))});
          seen.add(id);
          if (items.length >= 20000) return items.sort((a, b) => a.time - b.time);
        }
      }
      return items.sort((a, b) => a.time - b.time);
    }
    function dispose() {
      if (active && player && !player.isDisposed?.()) {
        try {
          clock = {...clock, paused: true};
          player.trigger('pause');
        } catch (_) {}
      }
      disposed = true; active = false;
      if (player) for (const [name, value] of original) player[name] = value;
      original.clear(); clock = null; prepared = null; held = null;
      heldMedia?.removeEventListener('play', preventWebContent);
      heldMedia = null;
      delete window.__bahaNativeTimeline;
      player = manager = media = null;
    }
    function acknowledgeDanmaku(ids) {
      if (!active || !live() || !Array.isArray(ids) || ids.length > 20000 ||
          !ids.every(id => typeof id === 'string' && /^\d{1,20}$/.test(id))) return false;
      const selected = manager || context().manager;
      if (!selected?.danmuList) return false;
      const consumed = new Set(ids), remaining = [];
      for (const [time, bucket] of Object.entries(selected.danmuList)) {
        if (!Array.isArray(bucket)) continue;
        const kept = bucket.filter(item => !consumed.has(String(item.sn)));
        if (kept.length) remaining[time] = kept;
      }
      selected.danmuList = remaining;
      return true;
    }
    return {prepare, hold, commit, sync, status, danmaku, acknowledgeDanmaku, dispose, backend,
      get active() {return active;}};
  };
})(); true;
