import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { parseHTML, DOMParser } from 'linkedom';

const folder = 'app/assets/adapters/';
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
      return { ok: true, url: responseURL, text: async () => body, json: async () => JSON.parse(body) };
    },
  });
  return { context, document: window.document, messages, requests };
}
const card = (id: string, title = '測試動畫') => `
<a class="theme-list-main" href="animeRef.php?sn=${id}">
<div onclick="animefun.toggleGather(500, ${id}, x)"></div>
<img class="theme-img" data-src="https://p2.bahamut.com.tw/${id}.jpg">
<p class="theme-name">${title}</p><span class="theme-number">共5集</span></a>`;
const historyRecord = (animeSn = 10, videoSn = 20, point = 960) => ({
  animeSn, videoSn, title: '測試動畫', cover: `https://p2.bahamut.com.tw/${animeSn}.jpg`,
  episode: '5', duration: 25, breakPoint: { breakPoint: point },
});

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

test('duplicate popularity cards cannot erase the official timeline schedule', () => {
  const fixture = setup(`<div id="blockVideoInSeason">
    <div data-animesn="10"><a class="anime-card-block" href="animeVideo.php?sn=20">
      <div class="anime-blocker"><img data-src="https://p2.bahamut.com.tw/landscape.jpg"></div>
      <p class="anime-name">測試動畫</p><span class="anime-hours">01:15</span>
      <div class="anime-episode"><p>第17集</p></div></a>
      <span class="anime-date-info"><svg><title>svg_is_active</title></svg>11/05 (四)</span>
    </div>
    <div data-animesn="10"><a class="anime-card-block" href="animeVideo.php?sn=20">
      <div class="anime-blocker"><img data-src="https://p2.bahamut.com.tw/landscape.jpg"></div>
      <p class="anime-name">測試動畫</p></a></div></div>`, '/');
  vm.runInContext(fs.readFileSync(folder + 'catalog.js', 'utf8').replaceAll('%KIND%', 'catalog'), fixture.context);
  assert.equal(fixture.messages[0].items.length, 1);
  assert.equal(fixture.messages[0].items[0].updateDay, 4);
  assert.equal(fixture.messages[0].items[0].updateTime, '01:15');
  assert.equal(fixture.messages[0].items[0].episodeLabel, '第17集');
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

test('detail excludes website action text and accepts both production credit headings', async () => {
  for (const heading of ['＜製作團隊＞', '＜STAFF＞']) {
    const fixture = setup('<main>bridge</main>', '/', {
      'https://ani.gamer.com.tw/animeRef.php?sn=10': `
        <div class="anime_name"><h1>測試動畫</h1><button onclick="animefun.toggleGather(500, 10, x)"></button></div>
        <div class="data-intro"><p>故事簡介 ${heading} 製作名單</p>
          <div class="link"><a class="link-button">作品資料<i class="material-icons">keyboard_arrow_down</i></a></div></div>
        <ul class="type-list"><li><span class="title">作品分類</span>
          <ul><li>冒險</li><li>奇幻</li></ul></li></ul>`
    });
    vm.runInContext(fs.readFileSync(folder + 'detail.js', 'utf8').replaceAll('%ANIME_ID%', '10'), fixture.context);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(fixture.messages[0]?.detail.description, '故事簡介');
    assert.equal(fixture.messages[0]?.detail.metadata[0].value, '冒險、奇幻');
  }
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
    <a class="user-info"><div class="avatar"><img src="https://avatar2.bahamut.com.tw/avataruserpic/f/i/fixture-user/fixture-user.png"></div>
      <div class="user-info-text"><p class="user-name">測試暱稱</p><span class="user-id">fixture-user</span></div></a>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a>${card('10')}
    <div class="page_number"><a href="mygather.php?page=2">2</a></div>`,
  '/mygather.php', {
    'https://ani.gamer.com.tw/mygather.php?page=2': card('11'),
    'https://api.gamer.com.tw/anime/v3/history.php?page=1':
      JSON.stringify({ data: { history: [historyRecord()], totalPage: 1 } }),
  });
  await vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8').replace(/\}\)\(\); true;\s*$/, '})();'), fixture.context);
  // The resource's async IIFE is followed by a true sentinel, as required by
  // WebView evaluateJavaScript. Let that IIFE finish before checking its output.
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fixture.messages[0]?.type, 'account-synced');
  assert.deepEqual(fixture.messages[0].profile, {
    id: 'fixture-user', displayName: '測試暱稱',
    avatar: 'https://avatar2.bahamut.com.tw/avataruserpic/f/i/fixture-user/fixture-user.png'
  });
  assert.equal(fixture.messages[0].favorites.length, 2);
  assert.equal(fixture.messages[0].history[0].videoId, '20');
  assert.equal(fixture.messages[0].history[0].progress, 0.64);
  assert.equal(fixture.messages[0].history[0].progressLabel, '16:00');
  assert.equal(fixture.requests.length, 2);
});

test('cloud history loads API pages instead of treating an inert HTML wrapper as empty', async () => {
  const fixture = setup(`<a class="btn-logout">登出</a><h1 class="theme-title">我的動畫</h1>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a><div class="history-wrapper"></div>`,
  '/mygather.php', {
    'https://api.gamer.com.tw/anime/v3/history.php?page=1':
      JSON.stringify({ data: { history: [historyRecord()], totalPage: 2 } }),
    'https://api.gamer.com.tw/anime/v3/history.php?page=2':
      JSON.stringify({ data: { history: [
        historyRecord(), historyRecord(11, 21, -1), { ...historyRecord(12, 22), breakPoint: {} },
      ], totalPage: 2 } }),
  });
  await vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8').replace(/\}\)\(\); true;\s*$/, '})();'), fixture.context);
  assert.equal(fixture.messages[0].type, 'account-synced');
  assert.equal(fixture.messages[0].history.length, 3);
  assert.equal(fixture.messages[0].history[1].progress, 1);
  assert.equal(fixture.messages[0].history[1].progressLabel, '觀看結束');
  assert.equal(fixture.messages[0].history[2].progress, undefined);
  assert.equal(fixture.messages[0].history[2].progressLabel, undefined);
  assert.equal(fixture.requests.length, 2);
});

test('malformed cloud history reports a sync error instead of an empty account', async () => {
  const fixture = setup(`<a class="btn-logout">登出</a><h1 class="theme-title">我的動畫</h1>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a>`, '/mygather.php', {
    'https://api.gamer.com.tw/anime/v3/history.php?page=1': JSON.stringify({ error: { code: 401 } }),
  });
  await vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8').replace(/\}\)\(\); true;\s*$/, '})();'), fixture.context);
  assert.deepEqual(fixture.messages, [{ type: 'account-error' }]);
});

test('an official empty history response is accepted without fabricating records', async () => {
  const fixture = setup(`<a class="btn-logout">登出</a><h1 class="theme-title">我的動畫</h1>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a>`, '/mygather.php', {
    'https://api.gamer.com.tw/anime/v3/history.php?page=1':
      JSON.stringify({ data: { history: [], totalPage: 0 } }),
  });
  await vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8').replace(/\}\)\(\); true;\s*$/, '})();'), fixture.context);
  assert.equal(fixture.messages[0].type, 'account-synced');
  assert.deepEqual(fixture.messages[0].history, []);
});

test('account profile never pairs one user identity with another user history', async () => {
  const fixture = setup(`
    <a class="btn-logout">登出</a><h1 class="theme-title">我的動畫</h1>
    <a class="user-info"><div class="avatar"><img src="https://attacker.test/avatar.png"></div>
      <p class="user-name">Other account</p><span class="user-id">other-user</span></a>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a>`, '/mygather.php');
  vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8'), fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(fixture.messages, [{ type: 'account-error' }]);
  assert.equal(fixture.requests.length, 0);
});

test('guest accounts produce no synthetic collection or viewing history', async () => {
  const fixture = setup('<h1>請先登入</h1>');
  vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8'), fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(fixture.messages, [{ type: 'account-guest' }]);
  assert.equal(fixture.requests.length, 0);
});

function playerFixture() {
  const fixture = setup(`<html><head></head><body><nav>官網導覽</nav>
    <div class="anime_name"><h1>測試動畫 [1]</h1><button onclick="animefun.toggleGather(500, 10, x)"></button></div>
    <div class="data-intro"><p>故事簡介</p><div class="link">作品資料</div></div>
    <div class="season"><a href="?sn=20">1</a><a href="?sn=21">2</a></div>
    <div id="video-container"><video-js id="ani_video"><video></video><div class="official-ad-controls"></div><div class="vjs-danmu"></div></video-js></div>
    </body></html>`, '/animeVideo.php?sn=20');
  const media = fixture.document.querySelector('video') as any;
  const core = { state: { playingVideo: true, playingAd: false, videoSn: 20 } };
  const commands: any[] = [];
  const fault = { code: 0 };
  const levels = [{ height: 720, enabled: true }, { height: 1080, enabled: true }];
  let tick = () => {};
  let stopped = false;
  Object.defineProperties(media, Object.fromEntries(Object.entries({
    duration: 1200, currentTime: 37, paused: false, ended: false, muted: false,
    playbackRate: 1, readyState: 4, error: null,
    buffered: { length: 1, end: () => 90 },
  }).map(([key, value]) => [key, { value, writable: true, configurable: true }])));
  (fixture.document.querySelector('#ani_video') as any).player = {
    usingPlugin: (name: string) => name === 'm3u8',
    m3u8: () => core, error: () => fault.code ? { code: fault.code } : null,
    qualityLevels: () => levels,
    play: async () => { commands.push(['play']); media.paused = false; },
    pause: () => { commands.push(['pause']); media.paused = true; },
    currentTime: (value: number) => { commands.push(['seek', value]); media.currentTime = value; },
    playbackRate: (value: number) => { commands.push(['rate', value]); media.playbackRate = value; },
    muted: (value?: boolean) => value === undefined ? media.muted : (media.muted = value),
  };
  fixture.context.window = { __bahaDocumentNonce: 'ticket', __bahaMediaSuspended: false };
  fixture.context.getComputedStyle = (node: any) => ({ display: node.style?.display || 'block', visibility: 'visible', opacity: '1' });
  fixture.context.setInterval = (callback: () => void) => { tick = callback; return 1; };
  fixture.context.clearInterval = () => { stopped = true; };
  vm.runInContext(fs.readFileSync(folder + 'player.js', 'utf8').replaceAll('%ANIME_ID%', '10'), fixture.context);
  return { ...fixture, core, media, commands, levels, fault, tick: () => tick(), stopped: () => stopped,
    bridge: fixture.context.window.__bahaPlayerBridge };
}

test('native player projects real metadata and uses the official core to gate controls', async () => {
  const fixture = playerFixture();
  const detail = fixture.messages.find(m => m.type === 'player-detail');
  const state = fixture.messages.find(m => m.type === 'player-state');
  assert.equal(detail.detail.description, '故事簡介');
  assert.equal(detail.detail.episodes.length, 2);
  assert.equal(state.videoId, '20');
  assert.equal(state.phase, 'content');
  assert.equal(state.position, 37);
  assert.ok(fixture.document.querySelector('.official-ad-controls'));
  assert.equal(await fixture.bridge.command('ticket', 'seek', 67), true);
  assert.deepEqual(fixture.commands, [['seek', 67]]);
  assert.equal(await fixture.bridge.command('ticket', 'quality', 1080), true);
  assert.deepEqual(fixture.levels.map(l => l.enabled), [false, true]);
  assert.equal(await fixture.bridge.command('ticket', 'quality', 1440), false);
  assert.equal(await fixture.bridge.command('ticket', 'danmaku', 0), true);
  assert.equal(fixture.messages.at(-1).danmaku, false);
  fixture.core.state.playingVideo = false;
  fixture.core.state.playingAd = true;
  assert.equal(await fixture.bridge.command('ticket', 'seek', 1000), false);
  assert.equal(await fixture.bridge.command('ticket', 'rate', 2), false);
  assert.equal(await fixture.bridge.command('ticket', 'quality', 720), false);
  fixture.tick();
  assert.equal(fixture.messages.at(-1).phase, 'advertisement');
  assert.equal(fixture.document.documentElement.classList.contains('baha-native-controls'), true);
  assert.deepEqual(fixture.commands, [['seek', 67]]);
  assert.equal(await fixture.bridge.command('ticket', 'pause'), true);
  assert.equal(fixture.media.paused, true);
  fixture.fault.code = 1015;
  fixture.tick();
  assert.equal(fixture.messages.at(-1).phase, 'error');
  assert.equal(await fixture.bridge.command('ticket', 'play'), false);
});

test('native player preserves age confirmation and rejects stale or suspended commands', async () => {
  const fixture = playerFixture();
  fixture.core.state.playingVideo = false;
  const age = fixture.document.createElement('div') as any;
  age.className = 'ncc-choosebar';
  age.innerHTML = '<button id="adult">同意</button>';
  age.getBoundingClientRect = () => ({ height: 50 });
  fixture.document.querySelector('#video-container')!.appendChild(age);
  fixture.tick();
  assert.equal(fixture.messages.at(-1).phase, 'age');
  assert.equal(await fixture.bridge.command('ticket', 'play'), false);
  assert.ok(fixture.document.querySelector('#adult'));
  age.remove();
  fixture.core.state.playingVideo = true;
  const identity = fixture.document.querySelector('.anime_name button')!;
  identity.setAttribute('onclick', 'animefun.toggleGather(500, 11, x)');
  fixture.tick();
  assert.equal(fixture.messages.at(-1).surfaceReady, false);
  assert.equal(await fixture.bridge.command('ticket', 'play'), false);
  identity.setAttribute('onclick', 'animefun.toggleGather(500, 10, x)');
  fixture.context.window.__bahaMediaSuspended = true;
  assert.equal(await fixture.bridge.command('ticket', 'play'), false);
  fixture.context.window.__bahaMediaSuspended = false;
  assert.equal(await fixture.bridge.command('old-ticket', 'seek', 0), false);
  fixture.context.window.__bahaDocumentNonce = 'another-document';
  fixture.tick();
  assert.equal(fixture.stopped(), true);
  assert.equal(fixture.document.querySelector('#baha-player-layout'), null);
  assert.deepEqual(fixture.commands, []);
});

test('single available quality distinguishes an explicit selection from automatic mode', async () => {
  const fixture = playerFixture();
  fixture.levels.splice(0, fixture.levels.length, { height: 360, enabled: true });
  fixture.tick();
  assert.deepEqual(Array.from(fixture.messages.at(-1).qualities), [360]);
  assert.equal(fixture.messages.at(-1).quality, 0);
  assert.equal(await fixture.bridge.command('ticket', 'quality', 360), true);
  assert.equal(fixture.messages.at(-1).quality, 360);
  assert.equal(await fixture.bridge.command('ticket', 'quality', 0), true);
  assert.equal(fixture.messages.at(-1).quality, 0);
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

test('Flutter resources contain both locales, a valid test fixture and no account snapshots', () => {
  const read = (file: string) => JSON.parse(fs.readFileSync('app/assets/i18n/' + file, 'utf8'));
  const hans = read('zh-Hans.json'), hant = read('zh-Hant.json'), catalog = JSON.parse(fs.readFileSync('app/test/fixtures/catalog.json', 'utf8'));
  assert.deepEqual(Object.keys(hans).sort(), Object.keys(hant).sort());
  assert.ok(catalog.items.length >= 20);
  assert.deepEqual(Object.keys(catalog).sort(), ['fetchedAt', 'items']);
  assert.ok(!fs.readdirSync('app/assets/data').some(name => /history|favorites|account/.test(name)));
  for (const item of catalog.items) assert.match(item.id, /^\d+$/);
});
