(function () {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  const items = new Map();
  const text = (node) => node?.textContent.replace(/\s+/g, ' ').trim() || '';
  const image = (node) => node?.getAttribute('data-src') || node?.getAttribute('src');
  const updateDate = (label) => {
    const match = label.match(/(\d{1,2})\/(\d{1,2})/);
    if (!match) return undefined;
    const today = new Date(Date.now() + 8 * 60 * 60 * 1000);
    const month = Number(match[1]), day = Number(match[2]);
    let year = today.getUTCFullYear();
    const difference = month - today.getUTCMonth() - 1;
    if (difference > 6) year--;
    else if (difference < -6) year++;
    const candidate = new Date(Date.UTC(year, month - 1, day));
    if (candidate.getUTCMonth() !== month - 1 || candidate.getUTCDate() !== day) return undefined;
    return candidate.toISOString().slice(0, 10);
  };
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
    // The page contains timeline and popularity copies of the same card.
    // The latter omits the date/time and must not erase the timeline metadata.
    const old = items.get(id);
    items.set(id, { id, title, cover, latestVideoId, sections: ['season'], ...old,
      episodeLabel: old?.episodeLabel || text(card.querySelector('.anime-episode p')),
      updateTime: old?.updateTime || text(card.querySelector('.anime-hours')),
      updateDay: old?.updateDay ?? (weekday ? '日一二三四五六'.indexOf(weekday) : undefined),
      updateDate: old?.updateDate ?? updateDate(text(parent.querySelector('.anime-date-info'))),
      views: old?.views || text(card.querySelector('.anime-watch-number p')) });
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
