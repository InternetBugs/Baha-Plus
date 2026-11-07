(function () {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  window.__bahaCreateNativeHlsQuality = function ({ isCurrent, onChange }) {
    let master = '', variants = new Map(), selected = 0, disposed = false;
    let fetchController = null, cancelSwitch = null, switching = false, generation = 0;
    const live = () => !disposed && isCurrent();
    function url(raw, base = location.href) {
      try {
        raw = window.__bahaCacheOriginalSource?.(raw) || raw;
        const value = new URL(raw, base);
        return value.origin === 'https://bahamut.akamaized.net' &&
          !value.username && !value['pass' + 'word'] &&
          /\.m3u8$/i.test(value.pathname) ? value.href : null;
      } catch (_) { return null; }
    }
    const current = (player, media) => url(player?.currentSource?.()?.src || media?.currentSrc);
    const owns = source => source === master || [...variants.values()].includes(source);
    const state = () => ({
      qualities: [...variants.keys()].sort((a, b) => b - a),
      quality: variants.has(selected) ? selected : 0
    });
    function parse(text, base) {
      const result = new Map();
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
        const source = next && !next.startsWith('#') && url(next, base);
        if (source && Number.isInteger(height) && height >= 144 && height <= 4320 &&
            result.size < 20 && !result.has(height)) result.set(height, source);
      }
      return result;
    }
    function update(player, media) {
      const source = current(player, media);
      if (!live() || !source || owns(source)) return state();
      fetchController?.abort();
      const controller = fetchController = new AbortController();
      const ticket = ++generation;
      master = source; variants = new Map(); selected = 0;
      const timer = setTimeout(() => controller.abort(), 12000);
      fetch(source, { credentials: 'omit', signal: controller.signal })
        .then(async response => {
          if (!response.ok || !url(response.url) ||
              new URL(response.url).origin !== new URL(source).origin) return;
          const text = await response.text();
          if (text.length > 250000 || !live() || ticket !== generation ||
              !owns(current(player, media))) return;
          variants = parse(text, response.url);
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
      return changeSource(current(player, media), selected, player, media, snapshot, true);
    }
    async function changeSource(target, height, player, media, snapshot, force = false) {
      if (!live() || switching || !target || !owns(current(player, media))) return false;
      const previous = current(player, media), previousChoice = selected;
      if (previous === target && !force) { selected = height; onChange(); return true; }
      const position = snapshot?.position ?? media.currentTime, rate = snapshot?.rate ?? media.playbackRate;
      const paused = snapshot?.paused ?? media.paused, muted = snapshot?.muted ?? media.muted;
      const type = player.currentSource?.()?.type || 'application/x-mpegURL';
      switching = true;
      function load(source) {
        return new Promise(resolve => {
          let finished = false;
          const done = ok => {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            player.off('loadedmetadata', ready);
            player.off('error', failed);
            cancelSwitch = null;
            if (ok && live() && current(player, media) === source) {
              try {
                const duration = player.duration();
                player.currentTime(Math.max(0, Math.min(position,
                  Number.isFinite(duration) ? duration : position)));
                player.playbackRate(rate);
                player.muted(muted);
                if (paused || window.__bahaMediaSuspended === true) player.pause();
                else player.play()?.catch(() => {});
              } catch (_) { ok = false; }
            } else ok = false;
            resolve(ok);
          };
          const ready = () => done(true), failed = () => done(false);
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
          player.one('loadedmetadata', ready);
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
        if (live()) onChange();
      }
    }
    function dispose() {
      disposed = true; generation++;
      fetchController?.abort();
      cancelSwitch?.();
    }
    return { update, state, select, reload, source: current, owns, isSwitching: () => switching, dispose };
  };
})(); true;
