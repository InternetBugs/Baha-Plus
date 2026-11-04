import fs from 'node:fs';
import * as OpenCC from 'opencc-js';

const fold = OpenCC.Converter({ from: 'tw', to: 'cn' });
const mapping = {};
for (let value = 0x3400; value <= 0x9fff; value++) {
  const character = String.fromCharCode(value);
  const converted = fold(character);
  if (converted !== character) mapping[character] = converted;
}
fs.writeFileSync('Sources/BahaCore/Resources/search-folding.json', JSON.stringify(mapping) + '\n');
console.log('Updated the native simplified/traditional search dictionary.');
