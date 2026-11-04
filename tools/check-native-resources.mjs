import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const core = 'Sources/BahaCore/Resources';
const read = name => JSON.parse(fs.readFileSync(path.join(core, name), 'utf8'));
const traditional = read('zh-Hant.json');
const simplified = read('zh-Hans.json');
assert.deepEqual(Object.keys(traditional).sort(), Object.keys(simplified).sort());
for (const [key, value] of [...Object.entries(traditional), ...Object.entries(simplified)]) {
  assert.equal(typeof value, 'string', `Invalid text: ${key}`);
  assert.ok(value.trim(), `Missing text: ${key}`);
}
const catalog = read('catalog-snapshot.json');
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
for (const filename of fs.readdirSync('Sources/BahaPlus/Resources').filter(name => name.endsWith('.js'))) {
  const script = fs.readFileSync(path.join('Sources/BahaPlus/Resources', filename), 'utf8')
    .replaceAll('%KIND%', 'catalog')
    .replaceAll('%ANIME_ID%', '10')
    .replaceAll('__BAHA_DESIRED__', 'true');
  assert.doesNotThrow(() => new vm.Script(script, { filename }));
}
const iconDirectory = 'Darwin/Assets.xcassets/AppIcon.appiconset';
const icons = JSON.parse(fs.readFileSync(path.join(iconDirectory, 'Contents.json'), 'utf8'));
for (const image of icons.images) {
  if (image.filename) assert.ok(fs.existsSync(path.join(iconDirectory, image.filename)), `Missing icon: ${image.filename}`);
}
console.log(`Validated ${Object.keys(traditional).length} bilingual messages, ${catalog.items.length} catalog entries, page adapters and iOS icons.`);
