
(async function() {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  window.__bahaAccountSync?.dispose();
  const ticket = window.__bahaDocumentNonce, source = location.href;
  const watch = __BAHA_WATCH_ACCOUNT__;
  let disposed = false, observer, interval, generation = 0, lastIdentity;
  const watcher = {dispose() {
    disposed = true;
    observer?.disconnect();
    clearInterval(interval);
    window.removeEventListener('message', loginFinished);
    window.removeEventListener('pagehide', watcher.dispose);
  }};
  window.__bahaAccountSync = watcher;
  function live() {
    return !disposed && location.href === source &&
      window.__bahaDocumentNonce === ticket && window.__bahaAccountSync === watcher;
  }
  function post(value) { if (live()) bahaPostJSON(JSON.stringify(value)); }
  function validOwner(id) {
    return typeof id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(id) &&
      id.toLowerCase() !== 'guest';
  }
  function safeAvatar(raw) {
    try {
      var url = new URL(raw, location.origin);
      if (url.protocol === 'https:' && url.hostname.endsWith('.bahamut.com.tw') &&
          !url.username && !url['pass' + 'word'] && (!url.port || url.port === '443')) return url.href;
    } catch (_) {}
  }
  function collectProfile(doc) {
    var owner = doc.querySelector('a.user-info');
    var id = owner?.querySelector('.user-id')?.textContent.trim();
    var displayName = owner?.querySelector('.user-name')?.textContent.trim();
    if (!validOwner(id) || !displayName) return null;
    var img = owner.querySelector('.avatar img');
    var raw = img && (img.getAttribute('data-src') || img.getAttribute('src'));
    return {id:id,displayName:displayName,avatar:raw ? safeAvatar(raw) : undefined};
  }
  function identity() {
    const login = window.User?.Login;
    if (typeof login?.getUserid === 'function') {
      const id = login.getUserid();
      if (!id || String(id).toLowerCase() === 'guest') return {guest:true};
      if (!validOwner(id)) throw Error('Invalid account identity');
      // The official API reflects the current session even when its menu and
      // server-rendered history link still describe the previous guest page.
      let user;
      try { user = login.getUser?.(); } catch (_) {}
      if (user?.userid && user.userid.toLowerCase() !== id.toLowerCase()) throw Error('Account identity mismatch');
      const fallback = collectProfile(document);
      const matching = fallback?.id.toLowerCase() === id.toLowerCase() ? fallback : null;
      return {id:id,profile:{
        id:id, displayName:user?.nickname || matching?.displayName || id,
        avatar:safeAvatar(user?.avatarUrl?.big || user?.avatarUrl?.small) || matching?.avatar
      },official:true};
    }
    const profile = collectProfile(document);
    if (profile) return {id:profile.id,profile:profile};
    const link = document.querySelector('a[href*="viewList.php"]');
    const url = link && new URL(link.getAttribute('href'),location.origin);
    const id = url?.searchParams.get('u');
    if (document.querySelector('.btn-logout') && url?.origin === location.origin && validOwner(id)) return {id:id};
    if (document.querySelector('a[href^="https://user.gamer.com.tw/login.php"]')) return {guest:true};
    return {};
  }
  function collectFavorites(doc) {
  var items = [], seen = {};
  doc.querySelectorAll('a.theme-list-main, a.anime-card-block').forEach(function(card) {
    var href = new URL(card.getAttribute('href') || '', location.origin);
    var control = card.querySelector('[onclick*="toggleGather"]');
    var match = (control && control.getAttribute('onclick') || '').match(/toggleGather\(\d+,\s*(\d+)/);
    var id = match ? match[1] : href.pathname === '/animeRef.php' ? href.searchParams.get('sn') : null;
    var titleEl = card.querySelector('.theme-name, .anime-name');
    var img = card.querySelector('img.theme-img, .anime-blocker img');
    if (!id || !/^\d{1,10}$/.test(id) || seen[id] || !titleEl || !img) return;
    var cover = img.getAttribute('data-src') || img.src;
    if (!/^https:\/\/[^/]+\.bahamut\.com\.tw\//.test(cover)) return;
    seen[id] = true;
    items.push({id:id, title:titleEl.textContent.trim(), cover:cover, poster:cover, sections:[]});
  });
  return items;
  }
  async function getPage(url, current) {
    var parsed = new URL(url, location.origin);
    if (parsed.origin !== location.origin || !['/mygather.php','/viewList.php'].includes(parsed.pathname)) throw Error('Invalid account page');
    var controller = new AbortController();
    var timer = setTimeout(function(){controller.abort();},12000);
    try {
      var response = await fetch(parsed.href,{credentials:'same-origin',signal:controller.signal});
      var finalUrl = new URL(response.url);
      if (!response.ok || finalUrl.origin !== location.origin ||
          finalUrl.pathname !== parsed.pathname) throw Error('Account page unavailable');
      var text = await response.text();
      current();
      return new DOMParser().parseFromString(text,'text/html');
    } finally { clearTimeout(timer); }
  }
  async function getHistory(current) {
    var history = [], seen = new Set(), totalPage = 1;
    for (var page = 1; page <= totalPage; page++) {
      var url = new URL('/anime/v3/history.php', 'https://api.gamer.com.tw');
      url.searchParams.set('page', String(page));
      var controller = new AbortController();
      var timer = setTimeout(function(){controller.abort();},12000);
      var response, body;
      try {
        response = await fetch(url.href,{credentials:'include',signal:controller.signal});
        if (!response.ok || new URL(response.url).origin !== url.origin ||
            new URL(response.url).pathname !== url.pathname) throw Error('History unavailable');
        body = await response.json();
      } finally { clearTimeout(timer); }
      current();
      var data = body && body.data;
      if (!data || !Array.isArray(data.history) ||
          !Number.isInteger(data.totalPage) || data.totalPage < 0 || data.totalPage > 50) throw Error('History format changed');
      totalPage = data.totalPage;
      data.history.forEach(function(item) {
        // Withdrawn titles remain in cloud history with empty title/artwork.
        // They cannot form a playable card, but must not abort account sync.
        if (item.isTakenDown === 1 || item.isTakenDown === true) return;
        var id = String(item.animeSn), videoId = String(item.videoSn);
        if (!/^\d{1,10}$/.test(id) || !/^\d{1,10}$/.test(videoId) ||
            typeof item.title !== 'string' || !item.title.trim() ||
            typeof item.episode !== 'string') throw Error('Invalid history record');
        var cover = new URL(item.cover);
        if (cover.protocol !== 'https:' || !cover.hostname.endsWith('.bahamut.com.tw') ||
            cover.username || cover.password || (cover.port && cover.port !== '443')) throw Error('Invalid history artwork');
        if (seen.has(id)) return;
        seen.add(id);
        var point = item.breakPoint && item.breakPoint.breakPoint;
        if ((point != null && (!Number.isFinite(point) || point < -1)) ||
            !Number.isFinite(item.duration) || item.duration < 0) throw Error('Invalid history progress');
        var progress = point == null ? undefined : point === -1 ? 1 : item.duration > 0 ? Math.min(1,point/(item.duration*60)) : undefined;
        var seconds = Math.max(0, Math.floor(point));
        var label = point === -1 ? '觀看結束' : point > 0 ? Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0') : undefined;
        var watchedAt = typeof item.watchTime === 'string' ? new Date(item.watchTime) : null;
        var nextVideoId = String(item.nextVideoSn);
        history.push({anime:{id:id,title:item.title.trim(),cover:cover.href,poster:cover.href,sections:[]},
          videoId:videoId,episodeLabel:item.episode,progress:progress,progressLabel:label,
          watchedAt:watchedAt && Number.isFinite(watchedAt.getTime()) ? watchedAt.toISOString() : undefined,
          nextVideoId:/^[1-9]\d{0,9}$/.test(nextVideoId) && nextVideoId !== videoId ? nextVideoId : undefined});
      });
      if (history.length > 1000) throw Error('History exceeds account limit');
    }
    return history;
  }
  async function sync(account, expected) {
    function current() {
      if (!live() || generation !== expected ||
          identity().id?.toLowerCase() !== account.id.toLowerCase()) throw Error('Stale account');
    }
    try {
      current();
      if (account.profile) post({type:'account-authenticated',profile:account.profile});
      // A login inside an iframe can change the account without replacing this
      // document. Fetch a fresh collection for the live official identity.
      var first = !account.official && location.pathname === '/mygather.php' &&
        document.querySelector('.theme-title')?.textContent.includes('我的動畫')
          ? document : await getPage('/mygather.php',current);
      if (!first.querySelector('.theme-title')?.textContent.includes('我的動畫')) throw Error('Collection page unavailable');
      var favorites = collectFavorites(first);
      var visited = new Set(['/mygather.php']);
      var queue = Array.from(first.querySelectorAll('.page_number a[href]')).map(function(a){return a.getAttribute('href');});
      while (queue.length && visited.size < 50) {
        var next = new URL(queue.shift(),location.origin);
        if (next.origin !== location.origin || next.pathname !== '/mygather.php' || visited.has(next.pathname+next.search)) continue;
        visited.add(next.pathname+next.search);
        var doc = await getPage(next.href,current);
        favorites = favorites.concat(collectFavorites(doc));
        queue = queue.concat(Array.from(doc.querySelectorAll('.page_number a[href]')).map(function(a){return a.getAttribute('href');}));
      }
      var profile = account.profile || collectProfile(first);
      if (profile && profile.id.toLowerCase() !== account.id.toLowerCase()) throw Error('Account identity mismatch');
      if (!account.official) {
        var historyLink = document.querySelector('a[href*="viewList.php"]');
        var historyUrl = historyLink && new URL(historyLink.getAttribute('href'),location.origin);
        if (historyUrl?.origin === location.origin && validOwner(historyUrl.searchParams.get('u')) &&
            historyUrl.searchParams.get('u').toLowerCase() !== account.id.toLowerCase()) throw Error('Account identity mismatch');
      }
      var history = await getHistory(current);
      current();
      favorites = Array.from(new Map(favorites.map(function(a){return [a.id,a];})).values());
      post({type:'account-synced',profile:profile,favorites:favorites,history:history});
      watcher.dispose();
    } catch(e) {
      if (live() && generation === expected) {
        post({type:'account-error'});
        watcher.dispose();
      }
    }
  }
  async function check() {
    if (!live()) { watcher.dispose(); return; }
    try {
      const account = identity();
      const key = account.id?.toLowerCase() || (account.guest ? 'guest' : 'unknown');
      if (key === lastIdentity) return;
      lastIdentity = key;
      const expected = ++generation;
      if (account.id) await sync(account,expected);
      else if (account.guest) post({type:'account-guest'});
      else post({type:'account-error'});
    } catch (_) {
      if (lastIdentity !== 'error') {
        lastIdentity = 'error';
        generation++;
        post({type:'account-error'});
      }
    }
  }
  function loginFinished(event) {
    if (event.origin === 'https://user.gamer.com.tw' && event.data === 'LoginFinish' &&
        Array.from(document.querySelectorAll('iframe')).some(frame => frame.contentWindow === event.source)) {
      void check();
    }
  }
  if (watch) {
    observer = new MutationObserver(() => { void check(); });
    observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
    interval = setInterval(() => { void check(); },500);
    window.addEventListener('message',loginFinished);
    window.addEventListener('pagehide',watcher.dispose);
  }
  await check();
  if (!watch) watcher.dispose();
})(); true;
