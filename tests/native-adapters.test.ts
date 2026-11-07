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
  const intervals = new Set<() => void>();
  const adapterWindow = {
    addEventListener: window.addEventListener.bind(window),
    removeEventListener: window.removeEventListener.bind(window),
    dispatchEvent: window.dispatchEvent.bind(window),
    Event: window.Event,
  };
  const context = vm.createContext({
    window: adapterWindow, document: window.document, MutationObserver: window.MutationObserver, DOMParser,
    location: new URL(`https://ani.gamer.com.tw${pathname}`), URL, Map, Set, JSON,
    AbortController, setTimeout: () => 0, clearTimeout: () => {},
    setInterval: (callback: () => void) => { intervals.add(callback); return callback; },
    clearInterval: (callback: () => void) => intervals.delete(callback),
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
  return { context, document: window.document, messages, requests, intervals };
}
function runAccount(fixture: ReturnType<typeof setup>, watch = false) {
  return vm.runInContext(fs.readFileSync(folder + 'account-sync.js', 'utf8')
    .replaceAll('__BAHA_WATCH_ACCOUNT__', String(watch))
    .replace(/\}\)\(\); true;\s*$/, '})();'), fixture.context) as Promise<void>;
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

test('season timeline derives actual dates across New Year instead of using ordinal date codes', () => {
  const fixture = setup(`<div id="blockVideoInSeason"><div data-animesn="10" data-date-code="1">
    <a class="anime-card-block" href="animeVideo.php?sn=20"><div class="anime-blocker">
    <img data-src="https://p2.bahamut.com.tw/episode.jpg"></div><p class="anime-name">測試動畫</p>
    <span class="anime-hours">23:30</span></a>
    <span class="anime-date-info">12/31 (三)</span></div></div>`, '/');
  vm.runInContext(`const SystemDate = Date;
    Date = class extends SystemDate {
      constructor(...args) { super(...(args.length ? args : ['2026-01-01T00:30:00Z'])); }
      static now() { return new SystemDate('2026-01-01T00:30:00Z').getTime(); }
    };`, fixture.context);
  vm.runInContext(fs.readFileSync(folder + 'catalog.js', 'utf8').replaceAll('%KIND%', 'catalog'), fixture.context);
  assert.equal(fixture.messages[0].items[0].updateDate, '2025-12-31');
  assert.equal(fixture.messages[0].items[0].updateTime, '23:30');
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
        </ul></section><div id="acg_review">
          <div class="score-overall-number">4.7</div>
          <div class="score-overall-people">894人評價</div>
        </div><script>var acgReview = new Bahamut.AcgReview('#acg_review', 894, {"1":23,"2":15,"3":42,"4":81,"5":733}, 60657, 4);</script>
        <a href="?sn=27">Related series</a><video autoplay></video>`
    }
  });
  vm.runInContext(fs.readFileSync(folder + 'detail.js', 'utf8').replaceAll('%ANIME_ID%', '10'), fixture.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fixture.messages[0].type, 'detail');
  assert.deepEqual(JSON.parse(JSON.stringify(fixture.messages[0].detail.episodes)),
                   [{ id: '20', label: '13' }, { id: '21', label: '14' }, { id: '22', label: 'SP' }]);
  assert.deepEqual(JSON.parse(JSON.stringify(fixture.messages[0].detail.rating)),
                   { value: 4.7, count: 894, distribution: [23, 15, 42, 81, 733] });
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
  await runAccount(fixture);
  // The resource's async IIFE is followed by a true sentinel, as required by
  // WebView evaluateJavaScript. Let that IIFE finish before checking its output.
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fixture.messages.at(-1)?.type, 'account-synced');
  assert.deepEqual(fixture.messages.at(-1).profile, {
    id: 'fixture-user', displayName: '測試暱稱',
    avatar: 'https://avatar2.bahamut.com.tw/avataruserpic/f/i/fixture-user/fixture-user.png'
  });
  assert.equal(fixture.messages.at(-1).favorites.length, 2);
  assert.equal(fixture.messages.at(-1).history[0].videoId, '20');
  assert.equal(fixture.messages.at(-1).history[0].progress, 0.64);
  assert.equal(fixture.messages.at(-1).history[0].progressLabel, '16:00');
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
  await runAccount(fixture);
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
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{ type: 'account-error' }]);
});

test('withdrawn history placeholders do not discard cloud favorites or playable history', async () => {
  for (const isTakenDown of [1, true]) {
    const fixture = setup('<h1 class="theme-title">我的動畫</h1>', '/mygather.php', {
      'https://ani.gamer.com.tw/mygather.php':
        `<h1 class="theme-title">我的動畫</h1>${card('10')}`,
      'https://api.gamer.com.tw/anime/v3/history.php?page=1':
        JSON.stringify({ data: { history: [
          historyRecord(),
          { ...historyRecord(11, 21), isTakenDown, title: '', cover: '' },
          historyRecord(12, 22, -1),
        ], totalPage: 1 } }),
    });
    fixture.context.window.User = { Login: { getUserid: () => 'fixture-user' } };
    await runAccount(fixture);
    const result = fixture.messages.at(-1);
    assert.equal(result.type, 'account-synced');
    assert.deepEqual(result.favorites.map((item: any) => item.id), ['10']);
    assert.deepEqual(result.history.map((item: any) => item.videoId), ['20', '22']);
    assert.equal(result.history[1].progress, 1);
    assert.ok(!fixture.messages.some(message => message.type === 'account-error'));
  }
});

test('invalid available history still fails validation instead of silently dropping account data', async () => {
  const fixture = setup(`<a class="btn-logout">登出</a><h1 class="theme-title">我的動畫</h1>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a>`, '/mygather.php', {
    'https://api.gamer.com.tw/anime/v3/history.php?page=1':
      JSON.stringify({ data: { history: [
        { ...historyRecord(), isTakenDown: 0, title: '' },
      ], totalPage: 1 } }),
  });
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{ type: 'account-error' }]);
});

test('an official empty history response is accepted without fabricating records', async () => {
  const fixture = setup(`<a class="btn-logout">登出</a><h1 class="theme-title">我的動畫</h1>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a>`, '/mygather.php', {
    'https://api.gamer.com.tw/anime/v3/history.php?page=1':
      JSON.stringify({ data: { history: [], totalPage: 0 } }),
  });
  await runAccount(fixture);
  assert.equal(fixture.messages[0].type, 'account-synced');
  assert.deepEqual(fixture.messages[0].history, []);
});

test('account profile never pairs one user identity with another user history', async () => {
  const fixture = setup(`
    <a class="btn-logout">登出</a><h1 class="theme-title">我的動畫</h1>
    <a class="user-info"><div class="avatar"><img src="https://attacker.test/avatar.png"></div>
      <p class="user-name">Other account</p><span class="user-id">other-user</span></a>
    <a href="viewList.php?u=fixture-user">觀看紀錄</a>`, '/mygather.php');
  await runAccount(fixture);
  assert.equal(fixture.messages.at(-1).type, 'account-error');
  assert.ok(!fixture.messages.some(message => message.type === 'account-synced'));
  assert.equal(fixture.requests.length, 0);
});

test('guest accounts produce no synthetic collection or viewing history', async () => {
  const fixture = setup('<a class="user-info" href="https://user.gamer.com.tw/login.php">請先登入</a>');
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{ type: 'account-guest' }]);
  assert.equal(fixture.requests.length, 0);
});

test('official identity survives a stale guest menu and does not require a history user link', async () => {
  for (const historyLink of ['', '<a href="viewList.php?u=guest">觀看紀錄</a>']) {
    const fixture = setup(`<h1 class="theme-title">我的動畫</h1>${historyLink}${card('99')}`, '/mygather.php', {
      'https://ani.gamer.com.tw/mygather.php': `<h1 class="theme-title">我的動畫</h1>${card('10')}`,
      'https://api.gamer.com.tw/anime/v3/history.php?page=1':
        JSON.stringify({ data: { history: [historyRecord()], totalPage: 1 } }),
    });
    fixture.context.window.User = { Login: {
      getUserid: () => 'fixture-user',
      getUser: () => ({ userid: 'fixture-user', nickname: '測試暱稱',
        avatarUrl: { big: 'https://avatar2.bahamut.com.tw/fixture-user.png' } }),
    } };
    await runAccount(fixture);
    assert.equal(fixture.messages[0].type, 'account-authenticated');
    assert.equal(fixture.messages[0].profile.displayName, '測試暱稱');
    assert.equal(fixture.messages.at(-1).type, 'account-synced');
    assert.equal(fixture.messages.at(-1).history[0].videoId, '20');
    assert.deepEqual(fixture.messages.at(-1).favorites.map((item: any) => item.id), ['10']);
    assert.ok(!fixture.messages.some(message => message.type === 'account-guest'));
  }
});

test('a failed history sync still reports the identified account and never fabricates a logout', async () => {
  const fixture = setup('<h1 class="theme-title">我的動畫</h1>', '/mygather.php', {
    'https://ani.gamer.com.tw/mygather.php': '<h1 class="theme-title">我的動畫</h1>',
    'https://api.gamer.com.tw/anime/v3/history.php?page=1': '{"error":{"code":401}}',
  });
  fixture.context.window.User = { Login: { getUserid: () => 'fixture-user' } };
  await runAccount(fixture);
  assert.deepEqual(fixture.messages.map(message => message.type),
    ['account-authenticated', 'account-error']);
  assert.equal(fixture.messages[0].profile.id, 'fixture-user');
});

test('unrecognized or partially loaded documents report an error without clearing the account', async () => {
  const fixture = setup('<h1>暫時無法提供服務</h1>');
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{ type: 'account-error' }]);
  assert.equal(fixture.requests.length, 0);
});

test('visible login watches official identity changes and cleans up after syncing', async () => {
  const fixture = setup('<h1 class="theme-title">我的動畫</h1>', '/mygather.php', {
    'https://ani.gamer.com.tw/mygather.php': '<h1 class="theme-title">我的動畫</h1>',
    'https://api.gamer.com.tw/anime/v3/history.php?page=1':
      JSON.stringify({ data: { history: [], totalPage: 0 } }),
  });
  let id = '';
  fixture.context.window.User = { Login: { getUserid: () => id } };
  await runAccount(fixture, true);
  assert.deepEqual(fixture.messages, [{ type: 'account-guest' }]);
  assert.equal(fixture.intervals.size, 1);
  id = 'fixture-user';
  for (const tick of fixture.intervals) tick();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(fixture.messages.map(message => message.type),
    ['account-guest', 'account-authenticated', 'account-synced']);
  assert.equal(fixture.intervals.size, 0);
});

test('login completion only triggers from the official child frame and pending identity is polled', async () => {
  const fixture = setup('<h1 class="theme-title">我的動畫</h1><iframe></iframe>', '/mygather.php', {
    'https://ani.gamer.com.tw/mygather.php': '<h1 class="theme-title">我的動畫</h1>',
    'https://api.gamer.com.tw/anime/v3/history.php?page=1':
      JSON.stringify({ data: { history: [], totalPage: 0 } }),
  });
  let id = '';
  fixture.context.window.User = { Login: { getUserid: () => id } };
  const frame = fixture.document.querySelector('iframe') as any;
  frame.contentWindow = {};
  await runAccount(fixture, true);
  id = 'fixture-user';
  function message(origin: string, source: any) {
    const event = new fixture.context.window.Event('message');
    Object.assign(event, { origin, source, data: 'LoginFinish' });
    fixture.context.window.dispatchEvent(event);
  }
  message('https://attacker.test', frame.contentWindow);
  message('https://user.gamer.com.tw', {});
  assert.equal(fixture.requests.length, 0);
  message('https://user.gamer.com.tw', frame.contentWindow);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fixture.messages.at(-1).type, 'account-synced');
});

test('old login watchers and pending account reads cannot publish into a newer operation', async () => {
  const fixture = setup('<h1 class="theme-title">我的動畫</h1>');
  let id = '';
  fixture.context.window.User = { Login: { getUserid: () => id } };
  fixture.context.window.__bahaDocumentNonce = 'old';
  await runAccount(fixture, true);
  fixture.context.window.__bahaDocumentNonce = 'new';
  id = 'fixture-user';
  for (const tick of fixture.intervals) tick();
  assert.equal(fixture.intervals.size, 0);
  assert.deepEqual(fixture.messages, [{ type: 'account-guest' }]);

  let finish: (value: any) => void = () => {};
  fixture.context.fetch = () => new Promise(resolve => { finish = resolve; });
  const pending = runAccount(fixture);
  assert.equal(fixture.messages.at(-1)?.type, 'account-authenticated');
  id = 'other-user';
  finish({ ok: true, url: 'https://ani.gamer.com.tw/mygather.php',
    text: async () => '<h1 class="theme-title">我的動畫</h1>' });
  await pending;
  assert.ok(!fixture.messages.some(message => message.type === 'account-synced'));
});

function mediaCompatibilityFixture(origin = 'https://ani.gamer.com.tw') {
  class Media {
    tagName = 'VIDEO';
    attributes = new Map<string, string>();
    requests: { cors: string | null; inline: boolean; src: string }[] = [];
    getAttribute(name: string) { return this.attributes.get(name) ?? null; }
    setAttribute(name: string, value: string) { this.attributes.set(name, value); }
    removeAttribute(name: string) { this.attributes.delete(name); }
    querySelector() { return null; }
    get src() { return this.getAttribute('src') || ''; }
    set src(value: string) {
      this.requests.push({
        cors: this.getAttribute('crossorigin'),
        inline: this.attributes.has('playsinline'),
        src: value,
      });
      this.setAttribute('src', value);
    }
    load() {
      this.requests.push({
        cors: this.getAttribute('crossorigin'),
        inline: this.attributes.has('playsinline'),
        src: this.src,
      });
    }
  }
  const context = vm.createContext({
    window: {}, location: new URL(`${origin}/animeVideo.php?sn=20`),
    HTMLMediaElement: Media, URL, WeakMap, Reflect,
    document: { querySelectorAll: () => [] },
    MutationObserver: class { observe() {} },
  });
  vm.runInContext(fs.readFileSync(folder + 'media-compat.js', 'utf8'), context);
  return {Media, context};
}

test('iOS HLS compatibility sets CORS before the first source request and restores ad attributes', () => {
  const {Media} = mediaCompatibilityFixture();
  const video = new Media();
  video.src = 'https://bahamut.akamaized.net/show/master.m3u8?signature=fixture';
  assert.deepEqual(video.requests[0], {
    cors: 'anonymous', inline: true,
    src: 'https://bahamut.akamaized.net/show/master.m3u8?signature=fixture',
  });
  video.src = 'https://ads.example.test/preroll.mp4';
  assert.equal(video.requests[1].cors, null);
  assert.equal(video.requests[1].inline, false);
  video.src = 'https://bahamut.akamaized.net/next/master.m3u8';
  assert.equal(video.requests[2].cors, 'anonymous');
});

test('iOS HLS compatibility also covers load and preserves an original CORS setting', () => {
  const {Media} = mediaCompatibilityFixture();
  const video = new Media();
  video.setAttribute('crossorigin', 'use-credentials');
  video.setAttribute('src', 'https://bahamut.akamaized.net/show/master.m3u8');
  video.load();
  assert.equal(video.requests[0].cors, 'anonymous');
  video.src = 'https://ads.example.test/preroll.mp4';
  assert.equal(video.requests[1].cors, 'use-credentials');
});

test('iOS HLS compatibility leaves other origins, other formats and audio unchanged', () => {
  for (const origin of ['https://ani.gamer.com.tw', 'https://user.gamer.com.tw']) {
    const {Media} = mediaCompatibilityFixture(origin);
    const video = new Media();
    const hls = 'https://bahamut.akamaized.net/show/master.m3u8';
    video.src = origin.includes('user.') ? hls : 'https://bahamut.akamaized.net/ad.mp4';
    assert.equal(video.requests[0].cors, null);
    const audio = new Media();
    audio.tagName = 'AUDIO';
    audio.src = hls;
    assert.equal(audio.requests[0].cors, null);
  }
});

function playerFixture(nativeHls = false) {
  const fixture = setup(`<html><head></head><body><nav>官網導覽</nav>
    <div class="anime_name"><h1>測試動畫 [1]</h1><button onclick="animefun.toggleGather(500, 10, x)"></button></div>
    <div class="data-intro"><p>故事簡介</p><div class="link">作品資料</div></div>
    <div id="acg_review"><div class="score-overall-number">4.7</div>
      <div class="score-overall-people">894人評價</div></div>
    <script>var acgReview = new Bahamut.AcgReview('#acg_review', 894, {"1":23,"2":15,"3":42,"4":81,"5":733}, 60657, 4);</script>
    <div class="season"><a href="?sn=20">1</a><a href="?sn=21">2</a></div>
    <div id="video-container"><video-js id="ani_video"><video></video><button class="vjs-big-play-button">播放</button><div class="official-ad-controls"></div><div class="vjs-danmu"></div></video-js></div>
    </body></html>`, '/animeVideo.php?sn=20');
  const media = fixture.document.querySelector('video') as any;
  const core = { state: { playingVideo: true, playingAd: false, videoSn: 20 } };
  const controls: { danmuManager?: any } = {};
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
    usingPlugin: (name: string) => ['m3u8', 'animePlayer'].includes(name),
    m3u8: () => core, animePlayer: () => controls,
    error: () => fault.code ? { code: fault.code } : null,
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
  if (nativeHls) {
    levels.length = 0;
    const master = 'https://bahamut.akamaized.net/series/master.m3u8';
    (fixture.document.querySelector('#ani_video') as any).player.currentSource =
      () => ({ src: master, type: 'application/x-mpegURL' });
    fixture.context.fetch = async () => ({
      ok: true, url: master, text: async () => `#EXTM3U
#EXT-X-STREAM-INF:RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:RESOLUTION=1280x720
720/index.m3u8`
    });
    vm.runInContext(fs.readFileSync(folder + 'native-hls.js', 'utf8'), fixture.context);
  }
  vm.runInContext(fs.readFileSync(folder + 'player.js', 'utf8').replaceAll('%ANIME_ID%', '10'), fixture.context);
  return { ...fixture, core, controls, media, commands, levels, fault, tick: () => tick(), stopped: () => stopped,
    bridge: fixture.context.window.__bahaPlayerBridge };
}

test('native HLS resolutions reach the Flutter bridge without enabling quality commands during ads', async () => {
  const fixture = playerFixture(true);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(Array.from(fixture.messages.at(-1).qualities), [720, 360]);
  assert.equal(fixture.messages.at(-1).quality, 0);
  fixture.core.state.playingVideo = false;
  fixture.core.state.playingAd = true;
  assert.equal(await fixture.bridge.command('ticket', 'quality', 720), false);
  fixture.bridge.dispose();
});

test('native player projects real metadata and uses the official core to gate controls', async () => {
  const fixture = playerFixture();
  const detail = fixture.messages.find(m => m.type === 'player-detail');
  const state = fixture.messages.find(m => m.type === 'player-state');
  assert.equal(detail.detail.description, '故事簡介');
  assert.equal(detail.detail.episodes.length, 2);
  assert.equal(detail.detail.rating.value, 4.7);
  assert.deepEqual(Array.from(detail.detail.rating.distribution), [23, 15, 42, 81, 733]);
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

test('official play button stays usable until native controls can operate', () => {
  const fixture = playerFixture();
  const button = fixture.document.querySelector('.vjs-big-play-button') as any;
  assert.equal(button.inert, true);
  fixture.media.duration = 0;
  fixture.tick();
  assert.equal(fixture.document.documentElement.classList.contains('baha-native-controls'), false);
  assert.equal(button.inert, false);
  assert.equal(button.getAttribute('aria-hidden'), 'false');
  fixture.media.duration = 1200;
  fixture.core.state.playingVideo = false;
  fixture.tick();
  assert.equal(button.inert, false);
  fixture.core.state.playingVideo = true;
  fixture.tick();
  assert.equal(button.inert, true);
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

function communityFixture(
  responses: Record<string, string | { html: string; url: string }> = {},
  pathname = '/',
) {
  const fixture = setup(`<html><head></head><body><a class="btn-logout">登出</a></body></html>`,
    pathname, responses);
  const identity = { id: 'reader' };
  const csrfCalls: string[] = [];
  fixture.context.TextEncoder = TextEncoder;
  fixture.context.URLSearchParams = URLSearchParams;
  fixture.context.FormData = FormData;
  fixture.context.window = {
    __bahaDocumentNonce: 'ticket',
    User: { Login: { getUserid: () => identity.id } },
    Bahamut: { Csrf: class {
      setCookie() { csrfCalls.push('cookie'); }
      getJqueryHeaders() { return { 'X-Bahamut-Csrf-Token': 'offline-token' }; }
    } },
  };
  const sent: { url: string; method: string; body: any; headers: any }[] = [];
  const offlineFetch = fixture.context.fetch;
  fixture.context.fetch = async (url: string, options: any = {}) => {
    // This closure is the only transport. It cannot reach the real network.
    sent.push({ url: String(url), method: options.method || 'GET',
      body: options.body, headers: options.headers });
    return offlineFetch(url);
  };
  function run(action: string, args: Record<string, any> = {}) {
    return vm.runInContext(
      fs.readFileSync(folder + 'community.js', 'utf8')
        .replaceAll('__BAHA_COMMUNITY_REQUEST__', JSON.stringify({ action, args })),
      fixture.context,
    ) as Promise<any>;
  }
  return { ...fixture, identity, sent, csrfCalls, run };
}
const boardURL = 'https://wall.gamer.com.tw/app/v2/comment_detail.php?service=4&serviceId=20&order=1';
const rawComment = (id: string, text = '故事 &amp; 心得') => ({
  id, userid: 'reader', name: '讀者', text, time: '1天前',
  propic: 'https://avatar2.bahamut.com.tw/reader.png', image: [],
  likeCount: 3, dislikeCount: 1, isLike: -1, commentCount: '2', isFolded: false,
});
const rawBoard = (extra: Record<string, any> = {}) => ({
  messageId: 123, commentCount: 15, nextPage: 2,
  comments: [rawComment('1'), rawComment('2')], ...extra,
});

test('community reads official per-episode comments, exact cursor, sort, replies and folded content', async () => {
  const fixture = communityFixture({
    [boardURL]: JSON.stringify(rawBoard()),
    [boardURL.replace('order=1', 'order=0') + '&nextPage=2']: JSON.stringify(
      rawBoard({ nextPage: 0, comments: [{ ...rawComment('3'), isFolded: true }] })),
    'https://wall.gamer.com.tw/app/v1/reply_detail.php?commentId=2':
      JSON.stringify({ comments: [rawComment('4')] }),
  });
  const first = await fixture.run('comments', { videoId: '20', order: 1, page: 0 });
  assert.equal(first.ok, true);
  assert.equal(first.messageId, '123');
  assert.equal(first.nextPage, 2);
  assert.deepEqual(Array.from(first.comments, (c: any) => c.id), ['2', '1']);
  assert.equal(first.comments[0].text, '故事 &amp; 心得');
  assert.equal(first.comments[0].replies, 2);
  const second = await fixture.run('comments', { videoId: '20', order: 0, page: 2 });
  assert.equal(second.comments[0].folded, true);
  const replies = await fixture.run('replies', { commentId: '2' });
  assert.equal(replies.comments[0].id, '4');
  assert.ok(fixture.sent.every(r => r.method === 'GET'));
});

test('community rejects changed endpoint redirects and invalid input without treating errors as empty boards', async () => {
  const fixture = communityFixture({
    [boardURL]: { url: 'https://attacker.test/login', html: JSON.stringify(rawBoard()) },
  });
  assert.equal((await fixture.run('comments', { videoId: '20', order: 1, page: 0 })).ok, false);
  assert.equal((await fixture.run('comments', { videoId: '20;alert(1)', order: 1, page: 0 })).code, 'input');
  assert.equal((await fixture.run('comments', { videoId: '20', order: 9, page: 0 })).code, 'input');
  assert.equal(fixture.sent.length, 1);
});

test('offline comment sends correct episode/message/reply, CSRF and text, then awaits acknowledgement', async () => {
  const fixture = communityFixture({
    [boardURL]: JSON.stringify(rawBoard()),
    'https://wall.gamer.com.tw/app/v1/comment_new.php': JSON.stringify({ commentId: 88 }),
  });
  const result = await fixture.run('comment-send', {
    owner: 'reader', videoId: '20', messageId: '123', commentId: '2', text: '  測試\n第二行 <tag>  ',
  });
  assert.equal(result.ok, true);
  assert.equal(result.id, '88');
  const request = fixture.sent.at(-1)!;
  assert.equal(request.method, 'POST');
  assert.equal(request.body.get('messageId'), '123');
  assert.equal(request.body.get('commentId'), '2');
  assert.equal(request.body.get('message'), '測試\n第二行 <tag>');
  assert.equal(request.headers['X-Bahamut-Csrf-Token'], 'offline-token');
  assert.deepEqual(fixture.csrfCalls, ['cookie']);
});

test('offline comment rejects guest, account mismatch, changed board, server failure and duplicate submission', async () => {
  const fixture = communityFixture({
    [boardURL]: JSON.stringify(rawBoard()),
    'https://wall.gamer.com.tw/app/v1/comment_new.php': JSON.stringify({ code: 9, message: '拒絕' }),
  });
  const args = { owner: 'reader', videoId: '20', messageId: '123', text: '測試' };
  assert.equal((await fixture.run('comment-send', { ...args, owner: 'other' })).code, 'login');
  assert.equal(fixture.sent.length, 0);
  assert.equal((await fixture.run('comment-send', { ...args, messageId: '999' })).code, 'stale');
  assert.equal(fixture.sent.filter(r => r.method === 'POST').length, 0);
  assert.equal((await fixture.run('comment-send', args)).code, 'rejected');
  fixture.context.window.__bahaCommunityLocks = new Set(['comment:123']);
  assert.equal((await fixture.run('comment-send', args)).code, 'busy');
  assert.equal(fixture.context.window.__bahaCommunityLocks.has('comment:123'), true);
  fixture.document.querySelector('.btn-logout')!.remove();
  fixture.identity.id = '';
  assert.equal((await fixture.run('comment-send', args)).code, 'login');
});

test('community uses current official identity while the menu is stale and rejects a stale logged-in menu', async () => {
  const fixture = communityFixture({
    'https://api.gamer.com.tw/ajax/common/topBar.php?type=light_0': '<ul></ul>',
    'https://api.gamer.com.tw/ajax/common/topBar.php?type=light_1': '<ul></ul>',
  });
  fixture.document.querySelector('.btn-logout')!.remove();
  assert.equal((await fixture.run('notifications', { owner: 'reader' })).ok, true);
  const staleMenu = fixture.document.createElement('a');
  staleMenu.className = 'btn-logout';
  fixture.document.body.append(staleMenu);
  fixture.identity.id = '';
  assert.equal((await fixture.run('notifications', { owner: 'reader' })).code, 'login');
});

test('offline comment drops a pending submission when the account or document changes before writing', async () => {
  for (const change of ['owner', 'document']) {
    const fixture = communityFixture({ [boardURL]: JSON.stringify(rawBoard()) });
    const original = fixture.context.fetch;
    fixture.context.fetch = async (...args: any[]) => {
      if (change === 'owner') fixture.identity.id = 'another';
      else fixture.context.window.__bahaDocumentNonce = 'new-document';
      return original(...args);
    };
    const result = await fixture.run('comment-send', {
      videoId: '20', messageId: '123', text: '測試',
    });
    assert.equal(result.code, 'stale');
    assert.equal(fixture.sent.filter(r => r.method === 'POST').length, 0);
  }
});

test('a background sync ticket change preserves a same-document read but still blocks writes', async () => {
  const fixture = communityFixture({ [boardURL]: JSON.stringify(rawBoard()) });
  const original = fixture.context.fetch;
  fixture.context.fetch = async (...args: any[]) => {
    fixture.context.window.__bahaDocumentNonce = 'background-account-sync';
    return original(...args);
  };
  const result = await fixture.run('comments', { videoId: '20', order: 1, page: 0 });
  assert.equal(result.ok, true);
  assert.equal(result.comments.length, 2);
  assert.equal(fixture.sent.filter(request => request.method === 'POST').length, 0);
});

test('notifications parse both official feeds, deduplicate episodes and exclude unrelated or unsafe targets', async () => {
  const html = `<ul><li><img src="https://p2.bahamut.com.tw/10.jpg">
    <a href="https://ani.gamer.com.tw/animeVideo.php?sn=20">測試動畫 [6] 更新囉！</a>
    <small>1天前</small></li>
    <li><a href="https://forum.gamer.com.tw/C.php?sn=20">論壇回覆</a></li>
    <li><a href="javascript:alert(1)">有新通知</a></li>
    <li><a href="https://attacker.test/animeVideo.php?sn=22">錯誤來源</a></li></ul>`;
  const fixture = communityFixture({
    'https://api.gamer.com.tw/ajax/common/topBar.php?type=light_0': html,
    'https://api.gamer.com.tw/ajax/common/topBar.php?type=light_1': html +
      '<li><a href="/animeVideo.php?sn=21">另一部 [3] 更新囉！</a><small>2天前</small></li>',
  });
  const result = await fixture.run('notifications');
  assert.equal(result.ok, true);
  assert.equal(result.owner, 'reader');
  assert.equal(result.items.length, 2);
  assert.equal(result.items[0].videoId, '20');
  assert.equal(result.items[0].time, '1天前');
  assert.equal(result.items[0].cover, 'https://p2.bahamut.com.tw/10.jpg');
  assert.ok(fixture.sent.every(r => r.method === 'GET'));
});

test('notification target resolves the official series using inert HTML without starting playback', async () => {
  const fixture = communityFixture({
    'https://ani.gamer.com.tw/animeVideo.php?sn=20': `
      <div class="anime_name"><h1>測試動畫 [6]</h1>
      <button onclick="animefun.toggleGather(500, 10, x)"></button></div>
      <img class="data-img" src="https://p2.bahamut.com.tw/10.jpg"><video autoplay></video>`,
  });
  const result = await fixture.run('notification-target', { videoId: '20' });
  assert.equal(result.anime.id, '10');
  assert.equal(result.anime.latestVideoId, '20');
  assert.equal(fixture.document.querySelector('video'), null);
});

function danmakuSendFixture() {
  const fixture = communityFixture({
    'https://ani.gamer.com.tw/ajax/getCSRFToken.php': 'offline-csrf',
    'https://ani.gamer.com.tw/ajax/danmuSet.php': JSON.stringify({ sn: 91 }),
  }, '/animeVideo.php?sn=20');
  const root = fixture.document.createElement('div');
  root.id = 'video-container';
  root.innerHTML = '<video-js id="ani_video"><video></video></video-js>';
  fixture.document.body.appendChild(root);
  const media = root.querySelector('video') as any;
  media.duration = 1200; media.currentTime = 37.8;
  const inserted: any[] = [];
  const core = { state: { playingVideo: true, playingAd: false, videoSn: 20 } };
  const controls = {
    danmuManager: { danmuPush: (value: any) => value, buildDanmu: (value: any) => inserted.push(value) }
  };
  (root.querySelector('#ani_video') as any).player = {
    usingPlugin: (name: string) => ['m3u8', 'animePlayer'].includes(name),
    m3u8: () => core, animePlayer: () => controls,
  };
  const args = { owner: 'reader', videoId: '20', text: '測試彈幕',
    color: '#FFFFFF', position: 0, size: 1 };
  return { ...fixture, core, media, inserted, args };
}

test('offline danmaku send uses current content time, official token, formatting and acknowledged display', async () => {
  const fixture = danmakuSendFixture();
  const result = await fixture.run('danmaku-send', fixture.args);
  assert.equal(result.ok, true);
  const body = fixture.sent.at(-1)!.body;
  assert.equal(body.get('sn'), '20');
  assert.equal(body.get('time'), '378');
  assert.equal(body.get('token'), 'offline-csrf');
  assert.equal(body.get('content'), '測試彈幕');
  assert.equal(body.get('color'), '#FFFFFF');
  assert.equal(body.get('position'), '0');
  assert.equal(fixture.inserted.length, 1);
});

test('offline danmaku enforces 60 UTF-8 bytes and rejects ads, stale episodes, suspension and server rejection', async () => {
  const fixture = danmakuSendFixture();
  assert.equal((await fixture.run('danmaku-send', { ...fixture.args, text: '字'.repeat(21) })).code, 'input');
  assert.equal(fixture.sent.length, 0);
  assert.equal((await fixture.run('danmaku-send', { ...fixture.args, videoId: '21' })).ok, false);
  fixture.core.state.playingAd = true;
  assert.equal((await fixture.run('danmaku-send', fixture.args)).ok, false);
  fixture.core.state.playingAd = false;
  fixture.context.window.__bahaMediaSuspended = true;
  assert.equal((await fixture.run('danmaku-send', fixture.args)).ok, false);
  fixture.context.window.__bahaMediaSuspended = false;
  const original = fixture.context.fetch;
  fixture.context.fetch = async (...args: any[]) => {
    if (String(args[0]).includes('danmuSet.php')) {
      return { ok: true, url: args[0], text: async () => JSON.stringify({ error: 1, msg: '拒絕' }) };
    }
    return original(...args);
  };
  assert.equal((await fixture.run('danmaku-send', fixture.args)).code, 'rejected');
  assert.equal(fixture.inserted.length, 0);
});

test('offline danmaku rechecks ad state after CSRF and never posts after entering an advertisement', async () => {
  const fixture = danmakuSendFixture();
  const original = fixture.context.fetch;
  fixture.context.fetch = async (...args: any[]) => {
    fixture.core.state.playingAd = true;
    return original(...args);
  };
  assert.equal((await fixture.run('danmaku-send', fixture.args)).ok, false);
  assert.equal(fixture.sent.filter(r => r.method === 'POST').length, 0);
});

test('danmaku display preferences apply to the official renderer and reject stale configuration', () => {
  const fixture = playerFixture();
  const changes: any[] = [];
  fixture.controls.danmuManager = {
    setDanmuOpacityRate: (value: any) => changes.push(['opacity', value]),
    setDanmuSizeRate: (value: any) => changes.push(['scale', value]),
    setDanmuModeAllow: (mode: any, value: any) => changes.push([mode, value]),
    setDanmuProcess: (value: any) => changes.push(['enabled', value]),
    cleanAll: () => changes.push(['clean']),
  };
  const settings = { enabled: true, opacity: .6, scale: 1.2, rolling: true, top: false, bottom: true };
  assert.equal(fixture.bridge.configure('ticket', settings), true);
  assert.ok(changes.some(([key, value]) => key === 'opacity' && value === .6));
  assert.ok(changes.some(([key, value]) => key === 'top' && value === false));
  const count = changes.length;
  fixture.tick();
  assert.equal(changes.length, count);
  assert.equal(fixture.bridge.configure('old-ticket', settings), false);
  assert.equal(fixture.bridge.configure('ticket', { ...settings, scale: 99 }), false);
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

test('favorite checks the current official identity instead of a stale login menu', async () => {
  for (const id of ['reader', '']) {
    const fixture = setup(`${id ? '' : '<a class="btn-logout">登出</a>'}
      <button onclick="animefun.toggleGather(500, 10, x)"></button>`);
    fixture.context.window.User = { Login: { getUserid: () => id } };
    let clicks = 0;
    const button = fixture.document.querySelector('button')!;
    button.addEventListener('click', () => { clicks++; button.classList.add('ordered'); });
    vm.runInContext(fs.readFileSync(folder + 'favorite-action.js', 'utf8')
      .replaceAll('%ANIME_ID%', '10').replace('__BAHA_DESIRED__', 'true'), fixture.context);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(fixture.messages.at(-1)?.type, id ? 'favorite-complete' : 'account-guest');
    assert.equal(clicks, id ? 1 : 0);
  }
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
