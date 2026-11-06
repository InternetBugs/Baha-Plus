
(async function() {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  function post(value) { bahaPostJSON(JSON.stringify(value)); }
  if (!document.querySelector('.btn-logout')) { post({type:'account-guest'}); return; }
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
    if (!historyUrl || !historyUrl.searchParams.get('u')) throw Error('History link unavailable');
    var historyDoc = location.pathname === '/viewList.php' ? document : await getPage(historyUrl.href);
    if (!historyDoc.querySelector('.history-wrapper')) throw Error('History format changed');
    var history = [];
    historyDoc.querySelectorAll('.user-watch-list').forEach(function(card) {
      var id = card.querySelector('[data-anime-sn]')?.getAttribute('data-anime-sn');
      var play = card.querySelector('a.play-btn');
      var videoId = play && new URL(play.getAttribute('href'),location.origin).searchParams.get('sn');
      var title = card.querySelector('.history-anime-title')?.textContent.trim();
      var img = card.querySelector('img.theme-img');
      var cover = img && (img.getAttribute('data-src') || img.src);
      if (!/^\d{1,10}$/.test(id||'') || !/^\d{1,10}$/.test(videoId||'') || !title || !/^https:\/\/[^/]+\.bahamut\.com\.tw\//.test(cover||'')) return;
      var progress = parseFloat(card.querySelector('.progress')?.style.width || '');
      var labels = card.querySelectorAll('.history-lastwatch');
      history.push({anime:{id:id,title:title,cover:cover,poster:cover,sections:[]},videoId:videoId,
        episodeLabel:card.querySelector('.user-lastwatch')?.textContent.trim() || '',
        progress:Number.isFinite(progress)?Math.min(1,Math.max(0,progress/100)):undefined,
        progressLabel:labels.length>1?labels[labels.length-1].textContent.trim():''});
    });
    favorites = Array.from(new Map(favorites.map(function(a){return [a.id,a];})).values());
    post({type:'account-synced',favorites:favorites,history:history});
  } catch(e) { post({type:'account-error'}); }
})(); true;
