(function () {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  function playlistURL(raw, base = location.href) {
    try {
      raw = window.__bahaCacheOriginalSource?.(raw) || raw;
      const value = new URL(raw, base);
      return value.origin === 'https://bahamut.akamaized.net' &&
        !value.username && !value['pass' + 'word'] && !value.hash &&
        /\.m3u8$/i.test(value.pathname) ? value.href : null;
    } catch (_) { return null; }
  }
  function parseVariants(text, base) {
    const result = new Map();
    if (typeof text !== 'string' || text.length > 250000 || !playlistURL(base)) return result;
    const lines = text.trim().split(/\r?\n/).map(line => line.trim());
    if (lines[0] !== '#EXTM3U') return result;
    const externalAudio = new Set(lines.filter(line =>
      line.startsWith('#EXT-X-MEDIA:') && /(?:[:,])TYPE=AUDIO(?:,|$)/.test(line) &&
      /(?:[:,])URI="/.test(line)).map(line => line.match(/GROUP-ID="([^"]+)"/)?.[1]));
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
      const resolution = lines[i].match(/(?:[:,])RESOLUTION=(\d+)x(\d+)(?:,|$)/);
      const audio = lines[i].match(/(?:[:,])AUDIO="([^"]+)"/)?.[1];
      if (!resolution || (audio && externalAudio.has(audio))) continue;
      const height = Number(resolution[2]);
      const next = lines.slice(i + 1).find(line => line);
      const source = next && !next.startsWith('#') && playlistURL(next, base);
      if (source && Number.isInteger(height) && height >= 144 && height <= 4320 &&
          result.size < 20 && !result.has(height)) result.set(height, source);
    }
    return result;
  }
  window.__bahaParseHlsVariants = parseVariants;
  window.__bahaCreateNativeHlsQuality = function ({ isCurrent, onChange }) {
    let master = '', variants = new Map(), selected = 0, disposed = false;
    let fetchController = null, cancelSwitch = null, switching = false, generation = 0;
    let restoring = null, initialSelection = false, initialSeed = null, checkSwitch = null;
    const live = () => !disposed && isCurrent();
    const url = playlistURL;
    const current = (player, media) => url(player?.currentSource?.()?.src || media?.currentSrc);
    const owns = source => source === master || [...variants.values()].includes(source);
    const state = () => ({
      qualities: [...variants.keys()].sort((a, b) => b - a),
      quality: variants.has(selected) ? selected : 0
    });
    function adoptInitial(player, media) {
      const seed = window.__bahaInitialHls;
      if (!live() || !seed || seed === initialSeed || !Array.isArray(seed.variants) ||
          seed.variants.length > 20 || seed.videoId !== new URL(location.href).searchParams.get('sn') ||
          !url(seed.master) || !Number.isInteger(seed.quality) || seed.quality < 144 ||
          current(player, media) !== seed.source) return;
      const entries = seed.variants;
      if (!entries.every(entry => Array.isArray(entry) && entry.length === 2 &&
          Number.isInteger(entry[0]) && entry[0] >= 144 && entry[0] <= 4320 && url(entry[1]))) return;
      const listed = new Map(entries);
      if (listed.size !== entries.length || listed.get(seed.quality) !== seed.source) return;
      fetchController?.abort(); generation++;
      master = seed.master; variants = listed; selected = seed.quality;
      initialSelection = true; initialSeed = seed;
    }
    function update(player, media) {
      adoptInitial(player, media);
      const source = current(player, media);
      if (!live() || !source || owns(source)) return state();
      fetchController?.abort();
      const controller = fetchController = new AbortController();
      const ticket = ++generation;
      master = source; variants = new Map(); selected = 0; initialSelection = false;
      const timer = setTimeout(() => controller.abort(), 12000);
      fetch(source, { credentials: 'omit', signal: controller.signal })
        .then(async response => {
          if (!response.ok || !url(response.url) ||
              new URL(response.url).origin !== new URL(source).origin) return;
          const text = await response.text();
          if (text.length > 250000 || !live() || ticket !== generation ||
              !owns(current(player, media))) return;
          variants = parseVariants(text, response.url);
          onChange();
        })
        .catch(() => {}) // A metadata failure leaves official automatic playback intact.
        .finally(() => clearTimeout(timer));
      return state();
    }
    async function select(height, player, media) {
      if (!live() || switching || !Number.isInteger(height) ||
          (height !== 0 && !variants.has(height)) || !owns(current(player, media))) return false;
      const target = height === 0 ? master : variants.get(height);
      if (!target || variants.size === 0) return false;
      return changeSource(target, height, player, media);
    }
    async function reload(player, media, snapshot) {
      const source = current(player, media);
      if (!source) return false;
      // VHS recovery also reloads the existing authorized source, without
      // fetching a new entitlement or changing the official content phase.
      if (!owns(source)) { master = source; variants = new Map(); selected = 0; initialSelection = false; }
      return changeSource(source, selected, player, media, snapshot, true);
    }
    async function changeSource(target, height, player, media, snapshot, force = false) {
      if (!live() || switching || !target || !owns(current(player, media))) return false;
      const previous = current(player, media), previousChoice = selected;
      if (previous === target && !force) { selected = height; onChange(); return true; }
      restoring = {position: snapshot?.position ?? media.currentTime, rate: snapshot?.rate ?? media.playbackRate,
        paused: snapshot?.paused ?? media.paused, muted: snapshot?.muted ?? media.muted};
      const type = player.currentSource?.()?.type || 'application/x-mpegURL';
      switching = true;
      function load(source) {
        return new Promise(resolve => {
          let finished = false, positioned = false, playRequested = false;
          const done = ok => {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            player.off('loadedmetadata', ready);
            player.off('canplay', ready);
            player.off('seeked', ready);
            player.off('error', failed);
            cancelSwitch = null;
            checkSwitch = null;
            if (ok && live() && current(player, media) === source) {
              try {
                player.playbackRate(restoring.rate);
                player.muted(restoring.muted);
                if (restoring.paused || window.__bahaMediaSuspended === true) player.pause();
                else if (!playRequested) player.play()?.catch(() => {});
              } catch (_) { ok = false; }
            } else ok = false;
            resolve(ok);
          };
          const ready = () => {
            if (!live() || current(player, media) !== source) { done(false); return; }
            try {
              if (!positioned) {
                const duration = player.duration();
                if (!(duration > 0)) return;
                positioned = true;
                // Metadata alone does not mean WebKit has completed its seek.
                player.currentTime(Math.max(0, Math.min(restoring.position, duration)));
              }
              player.playbackRate(restoring.rate);
              player.muted(restoring.muted);
              const paused = restoring.paused || window.__bahaMediaSuspended === true;
              if (paused) player.pause();
              else if (!playRequested) {
                // Native iOS HLS can wait for play() before producing canplay.
                // Start the intended playback after metadata/seek assignment,
                // rather than waiting for a readiness event it cannot reach.
                playRequested = true;
                player.play()?.catch(() => {
                  if (restoring && !restoring.paused && window.__bahaMediaSuspended !== true) failed();
                });
              }
              if (media.seeking || (!paused && media.readyState != null && media.readyState < 3)) return;
              done(true);
            } catch (_) { done(false); }
          }, failed = () => done(false);
          let remaining = 15000, checked = Date.now();
          const checkTimeout = () => {
            const now = Date.now();
            if (window.__bahaMediaSuspended !== true) remaining -= Math.min(1000, Math.max(0, now - checked));
            checked = now;
            if (remaining <= 0) failed();
            else timer = setTimeout(checkTimeout, 1000);
          };
          let timer = setTimeout(checkTimeout, 1000);
          cancelSwitch = failed;
          checkSwitch = ready;
          player.one('loadedmetadata', ready);
          player.on ? player.on('canplay', ready) : player.one('canplay', ready);
          player.on ? player.on('seeked', ready) : player.one('seeked', ready);
          player.one('error', failed);
          try { player.src({ src: source, type }); } catch (_) { failed(); }
        });
      }
      try {
        const ok = await load(target);
        if (!live()) return false;
        if (ok) selected = height;
        else if (previous !== target && current(player, media) === target && previous) {
          await load(previous);
          selected = previousChoice;
        }
        return ok;
      } finally {
        switching = false;
        restoring = null;
        if (live()) onChange();
      }
    }
    function dispose() {
      disposed = true; generation++;
      fetchController?.abort();
      cancelSwitch?.();
    }
    function suspend() {
      // Latch this across a complete background/foreground round trip, even
      // when loadedmetadata arrives only after the foreground event.
      if (restoring) restoring.paused = true;
      checkSwitch?.();
    }
    return { update, state, select, reload, source: current, owns, isSwitching: () => switching,
      hasInitialSelection: (player, media) => {
        adoptInitial(player, media);
        return initialSelection && owns(current(player, media));
      },
      sources: () => [...new Set([master, ...variants.values()])].filter(Boolean),
      timeline: () => restoring && {...restoring}, suspend, dispose };
  };
})(); true;
