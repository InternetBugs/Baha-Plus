import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const base = 'https://bahamut.akamaized.net/show/master.m3u8?auth=fixture';
function parse(text: string, source = base) {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync('app/assets/adapters/hls-cache-playlist.js', 'utf8'), context);
  const registered: {url: string; kind: string; role: string}[] = [];
  const result = context.parseHlsCachePlaylist(text, (raw: string) => {
    const url = new URL(raw, source);
    return url.origin === 'https://bahamut.akamaized.net' && !url.username &&
      !url.password && !url.hash ? url.href : null;
  }, (url: string, kind: string, role: string) => {
    registered.push({url, kind, role});
    return `http://localhost:12345/capability/media?u=${encodeURIComponent(url)}`;
  }, 'video');
  return {result: JSON.parse(JSON.stringify(result)), registered};
}

test('background HLS master rewrites real variant, audio and subtitle references', () => {
  const {result, registered} = parse(`#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio/list.m3u8?token=a"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",URI="sub/list.m3u8"
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=10000,URI="iframes/list.m3u8"
#EXT-X-STREAM-INF:RESOLUTION=1280x720,AUDIO="a"
720/list.m3u8?token=v`);
  assert.deepEqual(registered.map(item => [item.kind, item.role]), [
    ['playlist', 'audio'], ['playlist', 'subtitles'], ['playlist', 'iframes'], ['playlist', 'video'],
  ]);
  assert.ok(result.text.includes(encodeURIComponent('https://bahamut.akamaized.net/show/720/list.m3u8?token=v')));
  assert.equal(result.segments.length, 0);
  assert.equal(result.endList, false);
});

test('VOD cache windows retain timing, byte ranges, init segments and rotating keys', () => {
  const {result, registered} = parse(`#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="../key.bin?token=k",IV=0x01
#EXT-X-MAP:URI="init.mp4",BYTERANGE="100@0"
#EXTINF:6.25,
#EXT-X-BYTERANGE:4000@100
combined.mp4
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=NONE
#EXTINF:5.75,
#EXT-X-BYTERANGE:4000@4100
combined.mp4
#EXT-X-ENDLIST`);
  assert.equal(result.endList, true);
  assert.deepEqual(result.segments.map((segment: any) => [segment.start, segment.duration]), [
    [0, 6.25], [6.25, 5.75],
  ]);
  assert.deepEqual(result.segments[0].dependencies, [
    'https://bahamut.akamaized.net/key.bin?token=k',
    'https://bahamut.akamaized.net/show/init.mp4',
  ]);
  assert.deepEqual(result.segments[1].dependencies, [
    'https://bahamut.akamaized.net/show/init.mp4',
  ]);
  assert.ok(result.text.includes('IV=0x01'));
  assert.ok(result.text.includes('#EXT-X-BYTERANGE:4000@4100'));
  assert.ok(result.text.includes('#EXT-X-DISCONTINUITY'));
  assert.equal(registered.filter(item => item.kind === 'key').length, 1);
});

test('unsupported schemes, foreign origins and malformed playlists fall back safely', () => {
  for (const text of [
    '<html>Sign in</html>',
    '#EXTM3U\n#EXTINF:NaN,\na.ts',
    '#EXTM3U\n#EXTINF:-1,\na.ts',
    '#EXTM3U\n#EXTINF:6,\nhttps://attacker.test/a.ts',
    '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://license"\n#EXTINF:6,\na.ts',
    '#EXTM3U\n#EXTINF:6,\nhttps://user:pass@bahamut.akamaized.net/a.ts',
  ]) assert.throws(() => parse(text));
});

test('live manifests remain distinguishable and do not claim a finite VOD window', () => {
  const {result} = parse('#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:200\n#EXTINF:6,\na.ts');
  assert.equal(result.endList, false);
  assert.equal(result.segments.length, 1);
});
