import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const master = 'https://bahamut.akamaized.net/series/master.m3u8?auth=fixture';
const playlist = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
360/index.m3u8?auth=fixture
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=960x540
540/index.m3u8?auth=fixture
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
720/index.m3u8?auth=fixture
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080
1080/index.m3u8?auth=fixture`;
const flush = () => new Promise(resolve => setImmediate(resolve));

function fixture(body = playlist) {
  let live = true;
  let source = master;
  const events = new Map<string, Set<() => void>>();
  const requests: string[] = [];
  const media = {
    duration: 1200, currentTime: 37.4, playbackRate: 1.25, paused: false,
    muted: true, currentSrc: source,
  };
  const player = {
    currentSource: () => ({src: source, type: 'application/x-mpegURL'}),
    one: (name: string, handler: () => void) => {
      if (!events.has(name)) events.set(name, new Set());
      events.get(name)!.add(handler);
    },
    off: (name: string, handler: () => void) => events.get(name)?.delete(handler),
    src: (value: {src: string}) => {
      source = value.src; requests.push(source);
      media.currentSrc = source; media.currentTime = 0; media.duration = 0;
      media.paused = true;
    },
    duration: () => media.duration,
    currentTime: (value: number) => {media.currentTime = value;},
    playbackRate: (value: number) => {media.playbackRate = value;},
    muted: (value: boolean) => {media.muted = value;},
    play: async () => {media.paused = false;},
    pause: () => {media.paused = true;},
  };
  const context = vm.createContext({
    window: {}, location: new URL('https://ani.gamer.com.tw/animeVideo.php?sn=20'),
    URL, Map, Set, AbortController, setTimeout, clearTimeout,
    fetch: async () => ({ok: true, url: master, text: async () => body}),
  });
  vm.runInContext(fs.readFileSync('app/assets/adapters/native-hls.js', 'utf8'), context);
  const client = context.window.__bahaCreateNativeHlsQuality({
    isCurrent: () => live, onChange: () => {},
  });
  const emit = (name: string) => {
    if (name === 'loadedmetadata') media.duration = 1200;
    for (const handler of [...(events.get(name) || [])]) handler();
  };
  return {
    client, player, media, requests, context, emit,
    expire: () => {live = false; client.dispose();},
  };
}

test('native HLS exposes only server-listed resolutions and preserves state across manual/automatic switches', async () => {
  const f = fixture();
  f.client.update(f.player, f.media);
  await flush();
  assert.deepEqual(Array.from(f.client.state().qualities), [1080, 720, 540, 360]);
  const selected = f.client.select(720, f.player, f.media);
  assert.equal(f.requests[0], 'https://bahamut.akamaized.net/series/720/index.m3u8?auth=fixture');
  f.emit('loadedmetadata');
  assert.equal(await selected, true);
  assert.equal(f.client.state().quality, 720);
  assert.equal(f.media.currentTime, 37.4);
  assert.equal(f.media.playbackRate, 1.25);
  assert.equal(f.media.muted, true);
  assert.equal(f.media.paused, false);
  const automatic = f.client.select(0, f.player, f.media);
  assert.equal(f.requests[1], master);
  f.emit('loadedmetadata');
  assert.equal(await automatic, true);
  assert.equal(f.client.state().quality, 0);
  f.expire();
});

test('native HLS keeps a paused video paused and rejects unlisted or stale selections', async () => {
  const f = fixture();
  f.client.update(f.player, f.media);
  await flush();
  assert.equal(await f.client.select(1440, f.player, f.media), false);
  assert.equal(f.requests.length, 0);
  f.media.paused = true;
  const selected = f.client.select(540, f.player, f.media);
  f.emit('loadedmetadata');
  assert.equal(await selected, true);
  assert.equal(f.media.paused, true);
  const stale = f.client.select(360, f.player, f.media);
  f.expire();
  f.emit('loadedmetadata');
  assert.equal(await stale, false);
  assert.equal(f.media.currentTime, 0);
});

test('native HLS restores the previous authorized source if a selected variant fails', async () => {
  const f = fixture();
  f.client.update(f.player, f.media);
  await flush();
  const selected = f.client.select(720, f.player, f.media);
  f.emit('error');
  await flush();
  assert.equal(f.requests[1], master);
  f.emit('loadedmetadata');
  assert.equal(await selected, false);
  assert.equal(f.client.state().quality, 0);
  assert.equal(f.media.currentTime, 37.4);
  assert.equal(f.media.paused, false);
  f.expire();
});

test('native HLS rejects cross-origin variants, invalid resolutions and separate-audio variants', async () => {
  const f = fixture(`#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio.m3u8"
#EXT-X-STREAM-INF:RESOLUTION=1920x1080,AUDIO="audio"
video-only.m3u8
#EXT-X-STREAM-INF:RESOLUTION=1280x720
https://attacker.test/720.m3u8
#EXT-X-STREAM-INF:RESOLUTION=640x360
safe.m3u8
#EXT-X-STREAM-INF:RESOLUTION=99999x99999
invalid.m3u8`);
  f.client.update(f.player, f.media);
  await flush();
  assert.deepEqual(Array.from(f.client.state().qualities), [360]);
  assert.equal(await f.client.select(1080, f.player, f.media), false);
  f.expire();
});

test('cache source migration keeps the timeline and background completion stays paused', async () => {
  const f = fixture();
  f.client.update(f.player, f.media);
  await flush();
  const snapshot = {position: 37.4, rate: 1.25, paused: false, muted: true};
  const pending = f.client.reload(f.player, f.media, snapshot);
  assert.equal(f.requests[0], master);
  f.context.window.__bahaMediaSuspended = true;
  f.emit('loadedmetadata');
  assert.equal(await pending, true);
  assert.equal(f.media.currentTime, 37.4);
  assert.equal(f.media.playbackRate, 1.25);
  assert.equal(f.media.paused, true);
  assert.equal(f.media.muted, true);
  f.expire();
});
