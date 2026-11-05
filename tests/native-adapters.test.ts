import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { parseHTML, DOMParser } from 'linkedom';

const folder = 'Sources/BahaPlus/Resources/';
function setup(html: string, pathname = '/mygather.php',
               responses: Record<string, string | { html: string; url: string }> = {}) {
  const { window } = parseHTML(html);
  const messages: any[] = [];
  const requests: string[] = [];
  const context = vm.createContext({
    document: window.document, MutationObserver: window.MutationObserver, DOMParser,
    location: new URL(`https://ani.gamer.com.tw${pathname}`), URL, Map, Set, JSON,
    AbortController, setTimeout: () => 0, clearTimeout: () => {},
    bahaPostJSON: (raw: string) => messages.push(JSON.parse(raw)),
    fetch: async (url: string) => {
      const resolved = new URL(url, 'https://ani.gamer.com.tw').href;
      requests.push(resolved);
      const response = responses[resolved];
      assert.notEqual(response, undefined, `Unexpected URL: ${resolved}`);
      const body = typeof response === 'string' ? response : response.html;
      const responseURL = typeof response === 'string' ? resolved : response.url;
      return { ok: true, url: responseURL, text: async () => body };
    },
  });
  return { context, document: window.document, messages, requests };
}
const card = (id: string, title = '測試動畫') => `
<a class="theme-list-main" href="animeRef.php?sn=${id}">
<div onclick="animefun.toggleGather(500, ${id}, x)"></div>
<img class="theme-img" data-src="https://p2.bahamut.com.tw/${id}.jpg">
<p class="theme-name">${title}</p><span class="theme-number">共5集</span></a>`;

test('native catalog adapter preserves series/video identity, schedule and portrait across sections', () => {
  const fixture = setup(`<div id="blockVideoInSeason"><div data-animesn="10">
    <a class="anime-card-block" href="animeVideo.php?sn=20"><div class="anime-blocker">
    <img data-src="https://p2.bahamut.com.tw/landscape.jpg"></div><p class="anime-name">測試動畫</p>
    <span class="anime-hours">21:00</span><div class="anime-episode"><p>第5集</p></div></a>
    <span class="anime-date-info">11/04 (三)</span></div></div><div id="blockHotAnime">${card('10')}</div>`, '/');
  vm.runInContext(fs.readFileSync(folder + 'catalog.js', 'utf8').replaceAll('%KIND%', 'catalog'), fixture.context);
  const result = fixture.messages[0].items;
  assert.equal(result.length, 1);
  assert.equal(result[0].latestVideoId, '20');
  assert.equal(result[0].cover, 'https://p2.bahamut.com.tw/landscape.jpg');
  assert.equal(result[0].poster, 'https://p2.bahamut.com.tw/10.jpg');
  assert.equal(result[0].updateDay, 3);
  assert.deepEqual(Array.from(result[0].sections), ['season', 'hot']);
  assert.equal(fixture.messages[0].type, 'catalog');
});

test('native search results are not falsely labelled as popular catalog entries', () => {
  const fixture = setup(card('10'), '/search.php?keyword=test');
  vm.runInContext(fs.readFileSync(folder + 'catalog.js', 'utf8').replaceAll('%KIND%', 'search'), fixture.context);
  assert.equal(fixture.messages[0].type, 'search');
  assert.deepEqual(fixture.messages[0].items[0].sections, []);
});

test('detail reads inert HTML without creating a live player or modifying the current page', async () => {
  const fixture = setup('<main>原生資料橋接頁</main>', '/', {
    'https://ani.gamer.com.tw/animeRef.php?sn=10': `
      <div class="anime_name"><h1>測試動畫 [1]</h1><button onclick="animefun.toggleGather(500, 10, x)"></button></div>
      <div class="data-intro">故事簡介＜製作團隊＞其他</div>
      <a href="animeVideo.php?sn=20">1</a><a href="animeVideo.php?sn=21">2</a>
      <a href="https://attacker.test/animeVideo.php?sn=22">3</a>
      <video autoplay></video><script>throw new Error("Must never execute");</script>`
  });
  vm.runInContext(fs.readFileSync(folder + 'detail.js', 'utf8').replaceAll('%ANIME_ID%', '10'), fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fixture.messages[0].type, 'detail');
  assert.equal(fixture.messages[0].id, '10');
  assert.equal(fixture.messages[0].detail.title, '測試動畫');
  assert.equal(fixture.messages[0].detail.episodes.length, 2);
  assert.equal(fixture.document.querySelector('video'), null);
  assert.equal(fixture.document.querySelector('main')?.textContent, '原生資料橋接頁');
  assert.deepEqual(fixture.requests, ['https://ani.gamer.com.tw/animeRef.php?sn=10']);
});

test('detail mismatch returns an explicit failure instead of another series metadata', async () => {
  const fixture = setup('<main>bridge</main>', '/', {
    'https://ani.gamer.com.tw/animeRef.php?sn=10': '<div class="anime_name"><h1>Other</h1><button onclick="animefun.toggleGather(500, 11, x)"></button></div>'
  });
  vm.runInContext(fs.readFileSync(folder + 'detail.js', 'utf8').replaceAll('%ANIME_ID%', '10'), fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(fixture.messages, [{ type: 'detail-error', id: '10' }]);
});

test('detail resolves redirected season links and special episodes without loading a player', async () => {
  const fixture = setup('<main>bridge</main>', '/', {
    'https://ani.gamer.com.tw/animeRef.php?sn=10': {
      url: 'https://ani.gamer.com.tw/animeVideo.php?sn=20',
      html: `<div class="anime_name"><h1>測試動畫 [13]</h1><button onclick="animefun.toggleGather(500, 10, x)"></button></div>
        <section class="season"><ul>
          <li><a href="?sn=20" data-ani-video-sn="20">13</a></li>
          <li><a href="?sn=21" data-ani-video-sn="21">14</a></li>
          <li><a href="?sn=22" data-ani-video-sn="22">SP</a></li>
          <li><a href="?sn=20" data-ani-video-sn="20">duplicate</a></li>
          <li><a href="?sn=23" data-ani-video-sn="24">Wrong ID</a></li>
          <li><a href="https://attacker.test/animeVideo.php?sn=25">15</a></li>
          <li><a href="animeRef.php?sn=26">第一季</a></li>
        </ul></section><a href="?sn=27">Related series</a><video autoplay></video>`
    }
  });
  vm.runInContext(fs.readFileSync(folder + 'detail.js', 'utf8').replaceAll('%ANIME_ID%', '10'), fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fixture.messages[0].type, 'detail');
  assert.deepEqual(JSON.parse(JSON.stringify(fixture.messages[0].detail.episodes)),
                   [{ id: '20', label: '13' }, { id: '21', label: '14' }, { id: '22', label: 'SP' }]);
  assert.equal(fixture.document.querySelector('video'), null);
  assert.deepEqual(fixture.requests, ['https://ani.gamer.com.tw/animeRef.php?sn=10']);
});

test('native account adapter reads paginated cloud favorites and exact cloud viewing progress', async () => {
  const fixture = setup(`
    <a class="btn-logout">登出</a><h1 class="theme-title">我的動畫</h1>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a>${card('10')}
    <div class="page_number"><a href="mygather.php?page=2">2</a></div>`,
  '/mygather.php', {
    'https://ani.gamer.com.tw/mygather.php?page=2': card('11'),
    'https://ani.gamer.com.tw/viewList.php?u=fixture-user': `<div class="history-wrapper">
      <div class="user-watch-list"><div class="anime-card"><img class="theme-img" data-src="https://p2.bahamut.com.tw/10.jpg">
      <p class="history-anime-title">測試動畫</p><p class="history-lastwatch">觀看至 <span class="user-lastwatch">5</span> 集</p>
      <p class="history-lastwatch">觀看至 14 分 41 秒</p><div class="progress" style="width:64%"></div>
      <div data-anime-sn="10"></div><a class="play-btn" href="animeVideo.php?sn=20">播放</a></div></div></div>`,
  });
  await vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8').replace(/\}\)\(\); true;\s*$/, '})();'), fixture.context);
  // The resource's async IIFE is followed by a true sentinel, as required by
  // WebView evaluateJavaScript. Let that IIFE finish before checking its output.
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fixture.messages[0]?.type, 'account-synced');
  assert.equal(fixture.messages[0].favorites.length, 2);
  assert.equal(fixture.messages[0].history[0].videoId, '20');
  assert.equal(fixture.messages[0].history[0].progress, 0.64);
  assert.equal(fixture.messages[0].history[0].progressLabel, '觀看至 14 分 41 秒');
  assert.equal(fixture.requests.length, 2);
});

test('guest accounts produce no synthetic collection or viewing history', async () => {
  const fixture = setup('<h1>請先登入</h1>');
  vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8'), fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(fixture.messages, [{ type: 'account-guest' }]);
  assert.equal(fixture.requests.length, 0);
});

test('favorite action uses the official control and reports only verified resulting state', async () => {
  const fixture = setup('<a class="btn-logout">登出</a><div class="anime_name"><button onclick="animefun.toggleGather(500, 10, x)"></button></div>');
  const button = fixture.document.querySelector('button')!;
  button.addEventListener('click', () => button.classList.add('ordered'));
  const script = fs.readFileSync(folder + 'favorite-action.js', 'utf8')
    .replaceAll('%ANIME_ID%', '10').replace('__BAHA_DESIRED__', 'true');
  vm.runInContext(script, fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fixture.messages[0]?.type, 'favorite-complete');
  assert.equal(fixture.messages[0]?.saved, true);
  assert.equal(fixture.requests.length, 0);
});

test('favorite uses the official search card without opening a video page', async () => {
  const fixture = setup(`<a class="btn-logout">登出</a><a class="theme-list-main" href="animeRef.php?sn=10">
    <div class="btn-favorite" onclick="animefun.toggleGather(500, 10, x, 'btn-is-active')"></div></a>`, '/search.php?keyword=test');
  const control = fixture.document.querySelector('.btn-favorite')!;
  control.addEventListener('click', () => control.classList.add('btn-is-active'));
  const script = fs.readFileSync(folder + 'favorite-action.js', 'utf8')
    .replaceAll('%ANIME_ID%', '10').replace('__BAHA_DESIRED__', 'true');
  vm.runInContext(script, fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(fixture.messages, [{ type: 'favorite-complete', id: '10', saved: true }]);
  assert.equal(fixture.document.querySelector('video'), null);
  assert.equal(fixture.requests.length, 0);
});

test('SwiftUI resources contain both locales, valid public snapshot and no account snapshots', () => {
  const read = (file: string) => JSON.parse(fs.readFileSync('Sources/BahaCore/Resources/' + file, 'utf8'));
  const hans = read('zh-Hans.json'), hant = read('zh-Hant.json'), catalog = read('catalog-snapshot.json');
  assert.deepEqual(Object.keys(hans).sort(), Object.keys(hant).sort());
  assert.ok(catalog.items.length >= 20);
  assert.deepEqual(Object.keys(catalog).sort(), ['fetchedAt', 'items']);
  assert.ok(!fs.readdirSync('Sources/BahaCore/Resources').some(name => /history|favorites|account/.test(name)));
  for (const item of catalog.items) assert.match(item.id, /^\d+$/);
});
