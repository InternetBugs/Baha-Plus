import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const endpoint = 'https://api.gamer.com.tw/anime/v1/video_src.php?videoSn=20&deviceTypeUseCases=1';
const master = 'https://bahamut.akamaized.net/show/master.m3u8?auth=fixture';
const manifest = '#EXTM3U\n' + [360, 540, 720, 1080].map(height =>
  `#EXT-X-STREAM-INF:RESOLUTION=${height * 16 / 9}x${height}\n${height}/index.m3u8`
).join('\n');
const apiBody = () => ({
  data: {deviceid: 'fixture-device', srcUseCases: [
    {deviceType: 1, src: {playlist: master, thumbnail: 'https://bahamut.akamaized.net/show/thumb.json'}},
    {deviceType: 2, src: {playlist: master}},
  ]},
});

function fixture(quality = 1080, options: {
  body?: any; playlist?: string; failManifest?: boolean;
  origin?: string; hold?: Promise<void>;
} = {}) {
  const requests: {url: string; credentials?: string}[] = [];
  const saved = new Map<string, string>();
  const original = async (input: any, init?: RequestInit) => {
    const url = String(input.url || input);
    requests.push({url, credentials: init?.credentials});
    if (url === master) {
      await options.hold;
      if (options.failManifest) throw Error('Offline');
      const response = new Response(options.playlist ?? manifest);
      Object.defineProperty(response, 'url', {value: master});
      return response;
    }
    const response = new Response(JSON.stringify(options.body ?? apiBody()), {
      headers: {'content-type': 'application/json', 'content-length': '999'},
    });
    Object.defineProperty(response, 'url', {value: url});
    return response;
  };
  const context = vm.createContext({
    window: {fetch: original, localStorage: {setItem: (key: string, value: string) => saved.set(key, value)}},
    location: new URL(`${options.origin ?? 'https://ani.gamer.com.tw'}/animeVideo.php?sn=20`),
    URL, Map, Set, Headers, Response, AbortController, Reflect, setTimeout, clearTimeout,
  });
  vm.runInContext(fs.readFileSync('app/assets/adapters/native-hls.js', 'utf8'), context);
  vm.runInContext(fs.readFileSync('app/assets/adapters/initial-quality.js', 'utf8')
    .replaceAll('%QUALITY%', String(quality)), context);
  return {context, requests, saved, original};
}

for (const quality of [360, 540, 720, 1080]) {
  test(`saved ${quality}p is the first source delivered to the official player`, async () => {
    const f = fixture(quality);
    const response = await f.context.window.fetch(endpoint, {credentials: 'include'});
    const body = await response.json();
    assert.equal(body.data.srcUseCases[0].src.playlist,
      `https://bahamut.akamaized.net/show/${quality}/index.m3u8`);
    assert.equal(body.data.srcUseCases[1].src.playlist, master);
    assert.equal(body.data.deviceid, 'fixture-device');
    assert.equal(body.data.srcUseCases[0].src.thumbnail, apiBody().data.srcUseCases[0].src.thumbnail);
    assert.equal(response.url, endpoint);
    assert.equal(response.headers.get('content-length'), null);
    assert.deepEqual(f.requests, [
      {url: endpoint, credentials: 'include'},
      {url: master, credentials: 'omit'},
    ]);
    assert.equal(f.context.window.__bahaInitialHls.quality, quality);
    assert.equal(f.context.window.__bahaInitialHls.master, master);
    assert.equal(f.saved.get('ANIME_quality'), String(quality));
  });
}

test('automatic mode preserves the original API response and performs no preselection fetch', async () => {
  const f = fixture(0);
  assert.deepEqual(await (await f.context.window.fetch(endpoint)).json(), apiBody());
  assert.equal(f.requests.length, 1);
  assert.equal(f.context.window.__bahaInitialHls, undefined);
});

test('any server-listed resolution can be restored without a fixed quality catalog', async () => {
  const f = fixture(480, {playlist: '#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=854x480\n480/index.m3u8'});
  const body = await (await f.context.window.fetch(endpoint)).json();
  assert.equal(body.data.srcUseCases[0].src.playlist, 'https://bahamut.akamaized.net/show/480/index.m3u8');
  assert.equal(f.context.window.__bahaInitialHls.quality, 480);
});

test('the current preference is used for later official episode requests', async () => {
  const f = fixture(1080);
  f.context.window.__bahaPreferredQuality = 540;
  const selected = await (await f.context.window.fetch(endpoint)).json();
  assert.match(selected.data.srcUseCases[0].src.playlist, /\/540\/index\.m3u8$/);
  f.context.window.__bahaPreferredQuality = 0;
  assert.deepEqual(await (await f.context.window.fetch(endpoint)).json(), apiBody());
});

test('missing saved resolutions and network failures retain the authorized automatic source', async () => {
  for (const options of [{}, {failManifest: true}]) {
    const f = fixture(1440, options);
    assert.deepEqual(await (await f.context.window.fetch(endpoint)).json(), apiBody());
    assert.equal(f.context.window.__bahaPreferredQuality, 1440);
    assert.equal(f.context.window.__bahaInitialHls, undefined);
  }
});

test('official errors and foreign media sources are never altered', async () => {
  const failed = {error: {code: 1014, message: 'Entitlement required'}};
  const foreign = apiBody();
  foreign.data.srcUseCases[0].src.playlist = 'https://attacker.test/master.m3u8';
  for (const body of [failed, foreign]) {
    const f = fixture(1080, {body});
    assert.deepEqual(await (await f.context.window.fetch(endpoint)).json(), body);
    assert.equal(f.requests.length, 1);
    assert.equal(f.context.window.__bahaInitialHls, undefined);
  }
});

test('unrelated requests, mismatched episodes and other page origins remain untouched', async () => {
  for (const url of [
    endpoint.replace('videoSn=20', 'videoSn=21'),
    'https://api.gamer.com.tw/anime/v1/ads.php?videoSn=20',
    'https://attacker.test/anime/v1/video_src.php?videoSn=20',
  ]) {
    const f = fixture();
    assert.deepEqual(await (await f.context.window.fetch(url)).json(), apiBody());
    assert.equal(f.requests.length, 1);
  }
  const other = fixture(1080, {origin: 'https://attacker.test'});
  assert.equal(other.context.window.fetch, other.original);
});

test('foreign and separate-audio variants cannot become the initial media source', async () => {
  for (const playlist of [
    '#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1920x1080\nhttps://attacker.test/1080.m3u8',
    '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"\n#EXT-X-STREAM-INF:RESOLUTION=1920x1080,AUDIO="a"\n1080.m3u8',
  ]) {
    const f = fixture(1080, {playlist});
    assert.deepEqual(await (await f.context.window.fetch(endpoint)).json(), apiBody());
    assert.equal(f.context.window.__bahaInitialHls, undefined);
  }
});

test('navigation and a newer preference invalidate a pending initial selection', async () => {
  for (const change of [
    (f: ReturnType<typeof fixture>) => {f.context.location.search = '?sn=21';},
    (f: ReturnType<typeof fixture>) => {f.context.window.__bahaPreferredQuality = 720;},
  ]) {
    let finish = () => {};
    const hold = new Promise<void>(resolve => {finish = resolve;});
    const f = fixture(1080, {hold});
    const pending = f.context.window.fetch(endpoint);
    while (f.requests.length < 2) await new Promise(resolve => setImmediate(resolve));
    change(f); finish();
    assert.deepEqual(await (await pending).json(), apiBody());
    assert.equal(f.context.window.__bahaInitialHls, undefined);
  }
});
