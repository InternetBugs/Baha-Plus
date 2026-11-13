import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const core = 'app/assets/i18n';
const read = name => JSON.parse(fs.readFileSync(`${core}/${name}`, 'utf8'));
const traditional = read('zh-Hant.json');
const simplified = read('zh-Hans.json');
assert.deepEqual(Object.keys(traditional).sort(), Object.keys(simplified).sort());
for (const [key, value] of [...Object.entries(traditional), ...Object.entries(simplified)]) {
  assert.equal(typeof value, 'string', `Invalid text: ${key}`);
  assert.ok(value.trim(), `Missing text: ${key}`);
}
const catalog = JSON.parse(fs.readFileSync('app/test/fixtures/catalog.json', 'utf8'));
assert.ok(Number.isFinite(Date.parse(catalog.fetchedAt)));
assert.ok(catalog.items.length > 0);
assert.equal(new Set(catalog.items.map(item => item.id)).size, catalog.items.length);
for (const anime of catalog.items) {
  assert.match(anime.id, /^\d{1,10}$/);
  const cover = new URL(anime.cover);
  assert.equal(cover.protocol, 'https:');
  assert.ok(cover.hostname.endsWith('.bahamut.com.tw'));
  assert.ok(anime.title.trim());
}
for (const filename of fs.readdirSync('app/assets/adapters').filter(name => name.endsWith('.js'))) {
  const script = fs.readFileSync(`app/assets/adapters/${filename}`, 'utf8')
    .replaceAll('%ANIME_ID%', '10')
    .replaceAll('__BAHA_WATCH_ACCOUNT__', 'false');
  assert.doesNotThrow(() => new vm.Script(script, { filename }));
}
assert.ok(fs.existsSync('app/assets/fonts/NotoSansTC.ttf'));
assert.ok(fs.existsSync('app/assets/fonts/NotoSansSC.ttf'));
assert.ok(fs.existsSync('app/assets/fonts/OFL.txt'));
assert.ok(fs.existsSync('app/assets/fonts/OFL-SC.txt'));
assert.ok(!fs.readdirSync('app/assets/data').some(name => /account|history|favorites|snapshot/.test(name)));
console.log(`Validated ${Object.keys(traditional).length} bilingual messages, Flutter assets and official page adapters.`);
