(function () {
  if (location.origin !== 'https://ani.gamer.com.tw' ||
      location.pathname !== '/animeVideo.php' || window.__bahaInitialQualityInstalled) return;
  window.__bahaInitialQualityInstalled = true;
  window.__bahaPreferredQuality = %QUALITY%;
  const original = window.fetch;
  let generation = 0;
  const episode = () => new URL(location.href).searchParams.get('sn');
  const preference = () => {
    const value = window.__bahaPreferredQuality;
    return Number.isInteger(value) && value >= 144 && value <= 4320 ? value : 0;
  };
  try {
    if (preference()) window.localStorage.setItem('ANIME_quality', String(preference()));
  } catch (_) {}
  function playlist(raw) {
    try {
      const value = new URL(raw);
      return value.origin === 'https://bahamut.akamaized.net' && !value.username &&
        !value.password && !value.hash && /\.m3u8$/i.test(value.pathname) ? value.href : null;
    } catch (_) { return null; }
  }
  window.fetch = function (...args) {
    let endpoint;
    try {
      const input = args[0];
      endpoint = new URL(typeof input === 'string' ? input : input?.url || input?.href, location.href);
    } catch (_) { return Reflect.apply(original, this, args); }
    const videoId = episode(), quality = preference();
    if (!quality || !/^\d{1,10}$/.test(videoId || '') ||
        endpoint.origin !== 'https://api.gamer.com.tw' ||
        endpoint.pathname !== '/anime/v1/video_src.php' ||
        endpoint.searchParams.get('videoSn') !== videoId ||
        (args[1]?.method || args[0]?.method || 'GET').toUpperCase() !== 'GET') {
      return Reflect.apply(original, this, args);
    }
    const ticket = ++generation;
    const pending = Reflect.apply(original, this, args);
    return pending.then(async response => {
      let timer, controller;
      try {
        const returned = new URL(response.url);
        if (!response.ok || returned.origin !== endpoint.origin ||
            returned.pathname !== endpoint.pathname ||
            returned.searchParams.get('videoSn') !== videoId) return response;
        const body = await response.clone().json();
        if (body.error || !Array.isArray(body.data?.srcUseCases)) return response;
        const item = body.data.srcUseCases.find(value => Number(value.deviceType) === 1);
        const master = playlist(item?.src?.playlist);
        if (!master || typeof window.__bahaParseHlsVariants !== 'function') return response;
        controller = new AbortController();
        timer = setTimeout(() => controller.abort(), 8000);
        const manifest = await Reflect.apply(original, window, [master, {
          credentials: 'omit', signal: controller.signal
        }]);
        if (!manifest.ok || !playlist(manifest.url)) return response;
        const variants = window.__bahaParseHlsVariants(await manifest.text(), manifest.url);
        const target = variants.get(quality);
        if (!target || target === master || ticket !== generation || episode() !== videoId ||
            preference() !== quality || args[1]?.signal?.aborted || args[0]?.signal?.aborted) return response;
        item.src.playlist = target;
        const headers = new Headers(response.headers);
        headers.delete('content-length'); headers.delete('content-encoding');
        const selected = new Response(JSON.stringify(body), {
          status: response.status, statusText: response.statusText, headers
        });
        Object.defineProperty(selected, 'url', {value: response.url});
        window.__bahaInitialHls = {
          videoId, master, source: target, quality, variants: [...variants]
        };
        return selected;
      } catch (_) {
        return response;
      } finally {
        clearTimeout(timer);
      }
    });
  };
})(); true;
