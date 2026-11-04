(async function () {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  const expectedID = '%ANIME_ID%';
  if (!/^\d{1,10}$/.test(expectedID)) return;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
  // Read inert HTML. Loading the video's document into a live WebView merely
  // to obtain metadata could initialize playback and alter cloud watch history.
  const response = await fetch(`/animeRef.php?sn=${expectedID}`, {
    credentials: 'same-origin', signal: controller.signal
  });
  if (!response.ok || new URL(response.url).origin !== location.origin) throw Error('Detail unavailable');
  const doc = new DOMParser().parseFromString(await response.text(), 'text/html');
  const text = (node) => node?.textContent.replace(/\s+/g, ' ').trim() || '';
  const button = doc.querySelector('.anime_name button[onclick*="toggleGather"]');
  const id = button?.getAttribute('onclick')?.match(/toggleGather\(\d+,\s*(\d+)/)?.[1];
  if (id !== expectedID) throw Error('Unexpected series');
  const episodes = new Map();
  doc.querySelectorAll('a[href*="animeVideo.php?sn="]').forEach(a => {
    const url = new URL(a.getAttribute('href'), location.origin);
    const id = url.searchParams.get('sn'), label = text(a);
    if (url.origin === location.origin && /^\d{1,10}$/.test(id || '') &&
        /^(?:第\s*)?\d+(?:\.\d+)?(?:\s*集)?$/.test(label)) episodes.set(id, { id, label });
  });
  const img = doc.querySelector('.data-img');
  const detail = {
    title: text(doc.querySelector('.anime_name h1')).replace(/\s*\[[^\]]+\]\s*$/, ''),
    description: text(doc.querySelector('.data-intro')).split('＜製作團隊＞')[0].trim(),
    poster: img?.getAttribute('data-src') || img?.getAttribute('src'),
    episodes: [...episodes.values()],
    metadata: [...doc.querySelectorAll('.type-list > li')].map(li => ({
      label: text(li.querySelector('.title')), value: text(li.querySelector('.content')) || text(li.querySelector('ul'))
    })).filter(m => m.label && m.value)
  };
  bahaPostJSON(JSON.stringify({ type: 'detail', id, detail }));
  } catch {
    bahaPostJSON(JSON.stringify({ type: 'detail-error', id: expectedID }));
  } finally { clearTimeout(timer); }
})(); true;
