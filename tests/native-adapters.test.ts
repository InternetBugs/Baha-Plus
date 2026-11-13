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

test('login bridge reports identity only and never reads collection or history', async () => {
  const fixture = setup(`<a class="user-info"><span class="user-id">fixture-user</span>
    <span class="user-name">測試暱稱</span><div class="avatar">
    <img src="https://avatar2.bahamut.com.tw/user.png"></div></a>
    <div class="anime_list"><a href="/animeRef.php?sn=10">Existing favorite</a></div>`);
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{type:'account-authenticated', profile:{
    id:'fixture-user', displayName:'測試暱稱', avatar:'https://avatar2.bahamut.com.tw/user.png'
  }}]);
  assert.deepEqual(fixture.requests, []);
});

test('guest identity does not fabricate collections or fetch account endpoints', async () => {
  const fixture = setup('<a href="https://user.gamer.com.tw/login.php">登入</a>');
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{type:'account-guest'}]);
  assert.deepEqual(fixture.requests, []);
});

test('official login identity takes precedence over a stale menu and rejects external avatars', async () => {
  const fixture = setup('<span>guest menu</span>');
  fixture.context.window.User = {Login:{
    getUserid: () => 'fixture-user',
    getUser: () => ({userid:'fixture-user', nickname:'測試暱稱', avatarUrl:{big:'https://attacker.test/a.png'}})
  }};
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{type:'account-authenticated', profile:{id:'fixture-user', displayName:'測試暱稱'}}]);
  assert.deepEqual(fixture.requests, []);
});

test('unknown documents cannot confirm a logout', async () => {
  const fixture = setup('<h1>暫時無法提供服務</h1>');
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{type:'account-error'}]);
});

test('inconsistent login identities are not accepted as the current account', async () => {
  const fixture = setup('<div>Login</div>');
  fixture.context.window.User = {Login:{
    getUserid: () => 'fixture-user',
    getUser: () => ({userid:'previous-user', nickname:'Previous account'})
  }};
  await runAccount(fixture);
  assert.deepEqual(fixture.messages, [{type:'account-error'}]);
  assert.deepEqual(fixture.requests, []);
});

test('login watcher publishes identity and disposes without fetching account data', async () => {
  const fixture = setup('<div>Login</div>');
  let id = '';
  fixture.context.window.User = {Login:{getUserid: () => id}};
  await runAccount(fixture,true);
  assert.deepEqual(fixture.messages, [{type:'account-guest'}]);
  assert.equal(fixture.intervals.size,1);
  id = 'fixture-user';
  for (const tick of fixture.intervals) tick();
  assert.deepEqual(fixture.messages.map(message => message.type), ['account-guest','account-authenticated']);
  assert.equal(fixture.intervals.size,0);
  assert.deepEqual(fixture.requests, []);
});

test('login completion is accepted only from the official child frame', async () => {
  const fixture = setup('<iframe></iframe>');
  let id = '';
  fixture.context.window.User = {Login:{getUserid: () => id}};
  const frame = fixture.document.querySelector('iframe') as any;
  frame.contentWindow = {};
  await runAccount(fixture,true);
  id = 'fixture-user';
  function message(origin:string,source:any) {
    const event = new fixture.context.window.Event('message');
    Object.assign(event,{origin,source,data:'LoginFinish'});
    fixture.context.window.dispatchEvent(event);
  }
  message('https://attacker.test',frame.contentWindow);
  message('https://user.gamer.com.tw',{});
  assert.equal(fixture.messages.length,1);
  message('https://user.gamer.com.tw',frame.contentWindow);
  assert.equal(fixture.messages.at(-1).type,'account-authenticated');
  assert.deepEqual(fixture.requests, []);
});

test('replaced document invalidates the old login watcher', async () => {
  const fixture = setup('<div>Login</div>');
  let id = '';
  fixture.context.window.User = {Login:{getUserid: () => id}};
  fixture.context.window.__bahaDocumentNonce = 'old';
  await runAccount(fixture,true);
  fixture.context.window.__bahaDocumentNonce = 'new';
  id = 'fixture-user';
  for (const tick of fixture.intervals) tick();
  assert.equal(fixture.intervals.size,0);
  assert.deepEqual(fixture.messages, [{type:'account-guest'}]);
});

test('Windows session transport exposes the official top frame only and forwards raw messages unchanged', () => {
  const dart = fs.readFileSync('app/lib/data/windows_official_bridge.dart', 'utf8');
  const script = dart.match(/source:\s*'''([\s\S]*?)'''/)![1]
    .replaceAll('$windowsOfficialMessageHandler', 'bahaOfficialSession');
  const calls: any[] = [];
  const main: any = {flutter_inappwebview: {callHandler(...args: any[]) {
    calls.push(args);
    return Promise.resolve(null);
  }}};
  main.top = main;
  vm.runInNewContext(script, {window: main, location: new URL('https://ani.gamer.com.tw/')});
  const raw = JSON.stringify({requestId: 'current', type: 'account-guest'});
  main.baha.postMessage(raw);
  main.baha.postMessage({type: 'account-guest'});
  assert.deepEqual(calls, [['bahaOfficialSession', raw]]);
  assert.equal(Object.isFrozen(main.baha), true);
  for (const origin of ['https://ani.gamer.com.tw.evil.example', 'http://ani.gamer.com.tw', 'https://example.com']) {
    const foreign: any = {top: null};
    foreign.top = foreign;
    vm.runInNewContext(script, {window: foreign, location: new URL(origin)});
    assert.equal(foreign.baha, undefined);
  }
  const child: any = {top: {}};
  vm.runInNewContext(script, {window: child, location: new URL('https://ani.gamer.com.tw/')});
  assert.equal(child.baha, undefined);
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
