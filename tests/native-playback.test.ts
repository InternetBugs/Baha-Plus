import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {parseHTML} from 'linkedom';

function fixture(backend: string | null = 'android-exoplayer') {
  const {document} = parseHTML(`<html><head></head><body>
    <header>unused</header><div class="user-info">signed-in identity</div>
    <div class="anime_name"><button>original identity</button></div>
    <main><div class="video"><div id="video-container"><video src="old"></video>
      <div class="vjs-danmu"><span>old animated text</span></div></div></div>
      <iframe></iframe><section>unused board</section></main></body></html>`);
  const media: any = document.querySelector('video');
  Object.assign(media, {duration: 1200, currentTime: 10, paused: false,
    playbackRate: 1, muted: false, pause() {this.paused = true;}, load() {this.duration = NaN;}});
  const events: string[] = [];
  let vhsDisposed = false, live = true, policyError = false;
  const manager = {
    enabled: true, danmuList: {1000: [
      {sn: 1, time: 1000, text: '&lt;hello&gt;', mode: 'rolling', size: 16, color: '#FF0000'},
      {sn: 1, time: 1000, text: 'duplicate', mode: 'rolling'},
      {sn: 2, time: 1000, text: 'invalid', mode: 'unknown'},
    ]} as Record<string, any[]>,
    setDanmuProcess(value: boolean) {this.enabled = value;},
    cleanAll() {},
  };
  const player: any = {
    pause() {media.pause();}, isDisposed: () => false, error: () => policyError,
    currentSource: () => ({src: 'https://bahamut.akamaized.net/master.m3u8'}),
    tech: () => backend === 'ios-avplayer' ? {} : {vhs: {dispose() {vhsDisposed = true;}}},
    currentTime: () => media.currentTime, duration: () => media.duration,
    trigger(name: string) {events.push(name);},
  };
  const context: any = {matches: true, contentAuthorized: true, phase: 'content',
    player, media, manager, root: document.querySelector('#video-container')};
  const win: any = {__bahaNativeBackend: backend,
    __bahaParseHlsVariants: () => new Map([[360, 'https://bahamut.akamaized.net/360.m3u8']])};
  const sandbox = vm.createContext({window: win, document, URL, Map, Set,
    location: new URL('https://ani.gamer.com.tw/animeVideo.php?sn=20'),
    AbortController, setTimeout: () => 1, clearTimeout() {},
    fetch: async () => ({ok: true, url: 'https://bahamut.akamaized.net/master.m3u8',
      text: async () => '#EXTM3U'}),
  });
  vm.runInContext(fs.readFileSync('app/assets/adapters/native-playback.js', 'utf8'), sandbox);
  const bridge = win.__bahaCreateNativePlayback({context: () => context, isCurrent: () => live});
  return {bridge, context, media, player, manager, events, document, win,
    vhsDisposed: () => vhsDisposed, stale: () => {live = false;},
    rejectPolicy: () => {policyError = true;}};
}

for (const backend of ['android-exoplayer', 'ios-avplayer']) {
test(`${backend}: handoff is gated by the official ad/age/content state`, async () => {
  const f = fixture(backend);
  for (const phase of ['advertisement', 'age', 'verification', 'error']) {
    f.context.phase = phase;
    assert.equal(await f.bridge.prepare(), null);
    assert.equal(f.bridge.commit(), false);
  }
  f.context.phase = 'content'; f.context.contentAuthorized = false;
  assert.equal(await f.bridge.prepare(), null);
  f.context.contentAuthorized = true;
  f.stale();
  assert.equal(await f.bridge.prepare(), null);
});

test(`${backend}: handoff unloads web media and animations, retaining account/episode context`, async () => {
  const f = fixture(backend);
  const prepared = await f.bridge.prepare();
  assert.equal(prepared.variants[0].height, 360);
  f.media.currentTime = 42; // Playback may advance during native initialization.
  const handoff = f.bridge.commit();
  assert.equal(handoff.position, 42);
  assert.equal(f.media.getAttribute('src'), null);
  assert.equal(f.vhsDisposed(), backend === 'android-exoplayer');
  assert.equal(f.manager.enabled, false);
  assert.equal(f.document.querySelector('iframe'), null);
  assert.equal(f.document.querySelector('section'), null);
  assert.ok(f.document.querySelector('.user-info'));
  assert.ok(f.document.querySelector('.anime_name'));
  assert.ok(f.document.querySelector('.video'), 'official policy-error target remains available');
  assert.equal(f.document.querySelector('.vjs-danmu')!.children.length, 0);
});

test(`${backend}: official callbacks read the native clock and reject policy errors and stale documents`, async () => {
  const f = fixture(backend);
  await f.bridge.prepare(); f.bridge.commit();
  assert.equal(f.bridge.sync({position: 50, duration: 1200, paused: false}), true);
  assert.equal(f.player.currentTime(), 50);
  assert.deepEqual(f.events, ['play', 'timeupdate']);
  assert.equal(f.bridge.sync({position: 50, duration: 1200, paused: true}), true);
  assert.equal(f.player.currentTime(), 50);
  assert.equal(f.bridge.sync({position: -1, duration: 1200, paused: true}), false);
  f.rejectPolicy();
  assert.equal(f.bridge.sync({position: 51, duration: 1200, paused: false}), false);
  f.stale();
  assert.equal(f.bridge.sync({position: 52, duration: 1200, paused: false}), false);
});

test(`${backend}: danmaku decodes plain text, deduplicates IDs and rejects unsupported modes`, () => {
  const f = fixture(backend);
  const items = f.bridge.danmaku();
  assert.equal(items.length, 1);
  assert.equal(items[0].time, 1);
  assert.equal(items[0].text, '<hello>');
  assert.equal(items[0].color, '#FF0000');
});

test(`${backend}: acknowledged danmaku releases the web copy while preserving new arrivals`, async () => {
  const f = fixture(backend);
  await f.bridge.prepare(); f.bridge.commit();
  const batch = f.bridge.danmaku();
  f.manager.danmuList[2000] = [
    {sn: 3, time: 2000, text: 'new arrival', mode: 'top', size: 16, color: '#FFFFFF'},
  ];
  assert.equal(f.bridge.acknowledgeDanmaku(batch.map(item => item.id)), true);
  const remaining = f.bridge.danmaku();
  assert.equal(remaining.length, 1);
  assert.equal(remaining[0].id, '3');
});

test(`${backend}: exit notifies official pause/unlock handlers and restores the unloaded web clock`, async () => {
  const f = fixture(backend);
  const originalClock = f.player.currentTime;
  await f.bridge.prepare(); f.bridge.commit();
  f.bridge.sync({position: 75, duration: 1200, paused: false});
  f.bridge.dispose();
  assert.equal(f.events.at(-1), 'pause');
  assert.equal(f.player.currentTime, originalClock);
  assert.equal(f.win.__bahaNativeTimeline, undefined);
});
}

test('native handoff requires an explicitly supported host backend', async () => {
  for (const backend of [null, '', 'native-hls', 'unsupported']) {
    const f = fixture(backend);
    assert.equal(await f.bridge.prepare(), null);
    assert.equal(f.bridge.commit(), false);
  }
});
