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
  const pageURL = new URL(response.url);
  if (!response.ok || pageURL.origin !== location.origin ||
      !['/animeRef.php', '/animeVideo.php'].includes(pageURL.pathname)) throw Error('Detail unavailable');
  const doc = new DOMParser().parseFromString(await response.text(), 'text/html');
  const text = (node) => node?.textContent.replace(/\s+/g, ' ').trim() || '';
  const button = doc.querySelector('.anime_name button[onclick*="toggleGather"]');
  const id = button?.getAttribute('onclick')?.match(/toggleGather\(\d+,\s*(\d+)/)?.[1];
  if (id !== expectedID) throw Error('Unexpected series');
  const episodes = new Map();
  // animeRef redirects to a video document whose season links are "?sn=…".
  // Resolve against the response URL without ever loading its player/scripts.
  doc.querySelectorAll('.season a[href], a[href*="animeVideo.php?sn="]').forEach(a => {
    const url = new URL(a.getAttribute('href'), pageURL);
    const id = url.searchParams.get('sn'), label = text(a);
    const declaredID = a.getAttribute('data-ani-video-sn');
    const episodeLabel = a.closest('.season') ? label.length > 0 && label.length <= 100 :
      /^(?:第\s*)?\d+(?:\.\d+)?(?:\s*集)?$/.test(label);
    if (url.origin === location.origin && url.pathname === '/animeVideo.php' &&
        /^\d{1,10}$/.test(id || '') && (!declaredID || declaredID === id) &&
        episodeLabel && !episodes.has(id)) episodes.set(id, { id, label });
  });
  const img = doc.querySelector('.data-img');
  const score = Number(text(doc.querySelector('#acg_review .score-overall-number')));
  const countText = text(doc.querySelector('#acg_review .score-overall-people'));
  const count = Number((countText.match(/[0-9,]+/) || ['0'])[0].replaceAll(',', ''));
  let distribution = null;
  const scoreScript = [...doc.querySelectorAll('script')].map(script => script.textContent || '')
    .find(source => source.includes('new Bahamut.AcgReview'));
  const scoreMatch = scoreScript?.match(/new Bahamut\.AcgReview\([^,]+,\s*(\d+),\s*(\{[^}]+\})/);
  if (scoreMatch) {
    try {
      const values = JSON.parse(scoreMatch[2]);
      distribution = [1, 2, 3, 4, 5].map(star => Number(values[String(star)] || 0));
    } catch (_) { distribution = null; }
  }
  const intro = doc.querySelector('.data-intro')?.cloneNode(true);
  intro?.querySelectorAll('.link, .link-button, .material-icons, button, script, style')
    .forEach(node => node.remove());
  const detail = {
    title: text(doc.querySelector('.anime_name h1')).replace(/\s*\[[^\]]+\]\s*$/, ''),
    description: text(intro).split(/[＜<](?:製作團隊|制作团队|STAFF|CAST)[＞>]/i)[0].trim(),
    poster: img?.getAttribute('data-src') || img?.getAttribute('src'),
    ...(Number.isFinite(score) && score >= 0 && score <= 5 && Number.isInteger(count) &&
        count >= 0 && distribution?.length === 5
      ? { rating: { value: score, count, distribution } } : {}),
    episodes: [...episodes.values()],
    metadata: [...doc.querySelectorAll('.type-list > li')].map(li => ({
      label: text(li.querySelector('.title')),
      value: text(li.querySelector('.content')) ||
        [...li.querySelectorAll('ul > li')].map(text).filter(Boolean).join('、')
    })).filter(m => m.label && m.value)
  };
  bahaPostJSON(JSON.stringify({ type: 'detail', id, detail }));
  } catch {
    bahaPostJSON(JSON.stringify({ type: 'detail-error', id: expectedID }));
  } finally { clearTimeout(timer); }
})(); true;
