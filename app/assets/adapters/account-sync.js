
(async function() {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  function post(value) { bahaPostJSON(JSON.stringify(value)); }
  if (!document.querySelector('.btn-logout')) { post({type:'account-guest'}); return; }
  function collectProfile(doc) {
    var owner = doc.querySelector('a.user-info');
    var id = owner?.querySelector('.user-id')?.textContent.trim();
    var displayName = owner?.querySelector('.user-name')?.textContent.trim();
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id || '') || !displayName) return null;
    var img = owner.querySelector('.avatar img');
    var raw = img && (img.getAttribute('data-src') || img.getAttribute('src'));
    var avatar;
    if (raw) {
      var url = new URL(raw, location.origin);
      if (url.protocol === 'https:' && url.hostname.endsWith('.bahamut.com.tw') &&
          !url.username && !url.password && (!url.port || url.port === '443')) {
        avatar = url.href;
      }
    }
    return {id:id,displayName:displayName,avatar:avatar};
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
  async function getPage(url) {
    var parsed = new URL(url, location.origin);
    if (parsed.origin !== location.origin || !['/mygather.php','/viewList.php'].includes(parsed.pathname)) throw Error('Invalid account page');
    var controller = new AbortController();
    var timer = setTimeout(function(){controller.abort();},12000);
    var response;
    try { response = await fetch(parsed.href,{credentials:'same-origin',signal:controller.signal}); }
    finally { clearTimeout(timer); }
    if (!response.ok || new URL(response.url).origin !== location.origin) throw Error('Account page unavailable');
    return new DOMParser().parseFromString(await response.text(),'text/html');
  }
  async function getHistory() {
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
      var data = body && body.data;
      if (!data || !Array.isArray(data.history) ||
          !Number.isInteger(data.totalPage) || data.totalPage < 0 || data.totalPage > 50) throw Error('History format changed');
      totalPage = data.totalPage;
      data.history.forEach(function(item) {
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
        history.push({anime:{id:id,title:item.title.trim(),cover:cover.href,poster:cover.href,sections:[]},
          videoId:videoId,episodeLabel:item.episode,progress:progress,progressLabel:label});
      });
      if (history.length > 1000) throw Error('History exceeds account limit');
    }
    return history;
  }
  try {
    var first = location.pathname === '/mygather.php' ? document : await getPage('/mygather.php');
    if (!first.querySelector('.theme-title')?.textContent.includes('我的動畫')) throw Error('Collection page unavailable');
    var favorites = collectFavorites(first);
    var visited = new Set(['/mygather.php']);
    var queue = Array.from(first.querySelectorAll('.page_number a[href]')).map(function(a){return a.getAttribute('href');});
    while (queue.length && visited.size < 50) {
      var next = new URL(queue.shift(),location.origin);
      if (next.origin !== location.origin || next.pathname !== '/mygather.php' || visited.has(next.pathname+next.search)) continue;
      visited.add(next.pathname+next.search);
      var doc = await getPage(next.href);
      favorites = favorites.concat(collectFavorites(doc));
      queue = queue.concat(Array.from(doc.querySelectorAll('.page_number a[href]')).map(function(a){return a.getAttribute('href');}));
    }
    var historyLink = document.querySelector('a[href*="viewList.php"]');
    var historyUrl = historyLink && new URL(historyLink.getAttribute('href'),location.origin);
    if (!historyUrl || historyUrl.origin !== location.origin ||
        historyUrl.pathname !== '/viewList.php' || !historyUrl.searchParams.get('u')) throw Error('History link unavailable');
    var profile = collectProfile(document) || collectProfile(first);
    if (profile && profile.id.toLowerCase() !== historyUrl.searchParams.get('u').toLowerCase()) throw Error('Account identity mismatch');
    var history = await getHistory();
    favorites = Array.from(new Map(favorites.map(function(a){return [a.id,a];})).values());
    post({type:'account-synced',profile:profile,favorites:favorites,history:history});
  } catch(e) { post({type:'account-error'}); }
})(); true;
