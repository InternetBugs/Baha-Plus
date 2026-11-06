import fs from 'node:fs';
import * as OpenCC from 'opencc-js';

const fold = OpenCC.Converter({ from: 'tw', to: 'cn' });
const traditional = OpenCC.Converter({ from: 'cn', to: 'tw' });
const mapping = {};
const traditionalMapping = {};
for (let value = 0x3400; value <= 0x9fff; value++) {
  const character = String.fromCharCode(value);
  const converted = fold(character);
  if (converted !== character) mapping[character] = converted;
  const traditionalCharacter = traditional(character);
  if (traditionalCharacter !== character) traditionalMapping[character] = traditionalCharacter;
}
fs.writeFileSync('app/assets/data/search-folding.json', JSON.stringify(mapping) + '\n');
fs.writeFileSync('app/assets/data/search-traditional.json', JSON.stringify(traditionalMapping) + '\n');
console.log('Updated the Flutter simplified/traditional search dictionary.');
