(function () {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  const items = new Map();
  const text = (node) => node?.textContent.replace(/\s+/g, ' ').trim() || '';
  const image = (node) => node?.getAttribute('data-src') || node?.getAttribute('src');
  const idFrom = (card) => {
    const action = card.querySelector('[onclick*="toggleGather"]')?.getAttribute('onclick') || '';
    const match = action.match(/toggleGather\(\d+,\s*(\d+)/);
    if (match) return match[1];
    const url = new URL(card.getAttribute('href') || '', location.origin);
    return url.origin === location.origin && url.pathname === '/animeRef.php' ? url.searchParams.get('sn') : null;
  };
  document.querySelectorAll('#blockVideoInSeason .anime-card-block').forEach(card => {
    const parent = card.closest('[data-animesn]');
    const id = parent?.getAttribute('data-animesn');
    const title = text(card.querySelector('.anime-name'));
    const cover = image(card.querySelector('.anime-blocker img'));
    const url = new URL(card.getAttribute('href'), location.origin);
    const latestVideoId = url.searchParams.get('sn');
    if (!/^\d{1,10}$/.test(id || '') || !title || !cover ||
        url.origin !== location.origin || !/^\d{1,10}$/.test(latestVideoId || '')) return;
    const weekday = text(parent.querySelector('.anime-date-info')).match(/[（(]([日一二三四五六])[）)]/)?.[1];
    items.set(id, { id, title, cover, latestVideoId, sections: ['season'],
      episodeLabel: text(card.querySelector('.anime-episode p')),
      updateTime: text(card.querySelector('.anime-hours')),
      updateDay: weekday ? '日一二三四五六'.indexOf(weekday) : undefined,
      views: text(card.querySelector('.anime-watch-number p')) });
  });
  document.querySelectorAll('a.theme-list-main').forEach(card => {
    const id = idFrom(card), title = text(card.querySelector('.theme-name'));
    const cover = image(card.querySelector('img.theme-img'));
    if (!/^\d{1,10}$/.test(id || '') || !title || !cover) return;
    const old = items.get(id);
    const section = card.closest('#blockAnimeNewArrive') ? 'new' : 'hot';
    const sections = '%KIND%' === 'search' ? [] : [...new Set([...(old?.sections || []), section])];
    items.set(id, { id, title, cover, poster: cover,
      episodeLabel: text(card.querySelector('.theme-number')),
      year: text(card.querySelector('.theme-time')).match(/\d{4}\/\d{2}/)?.[0],
      ...old, sections, poster: cover });
  });
  bahaPostJSON(JSON.stringify({ type: '%KIND%', items: [...items.values()], fetchedAt: new Date().toISOString() }));
})(); true;
