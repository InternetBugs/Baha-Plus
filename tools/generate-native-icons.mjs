import fs from 'node:fs';
import path from 'node:path';
import sharp from 'sharp';

const assetPath = path.resolve('Darwin/Assets.xcassets/AppIcon.appiconset');
const manifest = JSON.parse(fs.readFileSync(path.join(assetPath, 'Contents.json'), 'utf8'));
for (const image of manifest.images) {
  if (!image.filename) continue;
  const size = Math.round(Number(image.size.split('x')[0]) * Number(image.scale.replace('x', '')));
  await sharp('assets/brand.svg').resize(size, size).flatten({ background: '#f1f5ee' })
    .removeAlpha().png().toFile(path.join(assetPath, image.filename));
}
const foreground = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="108" height="108" viewBox="0 0 108 108"><rect x="26" y="28" width="56" height="52" rx="16" fill="#d85f3d" transform="rotate(-7 54 54)"/><path d="M47 41L47 66L66 53.5Z" fill="#ffffff"/><rect x="75" y="24" width="10" height="10" rx="3" fill="#91ad83"/></svg>`);
const monochrome = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="108" height="108"><defs><mask id="mark"><rect x="26" y="28" width="56" height="52" rx="16" fill="white"/><path d="M47 41L47 66L66 53.5Z" fill="black"/></mask></defs><rect width="108" height="108" fill="black" mask="url(#mark)"/></svg>`);
for (const [density, scale] of Object.entries({ mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 })) {
  const folder = path.resolve(`Android/app/src/main/res/mipmap-${density}`);
  const size = Math.round(108 * scale);
  await sharp(foreground).resize(size, size).png().toFile(path.join(folder, 'ic_launcher_foreground.png'));
  await sharp(monochrome).resize(size, size).png().toFile(path.join(folder, 'ic_launcher_monochrome.png'));
  await sharp({ create: { width: size, height: size, channels: 4, background: '#f1f5ee' } })
    .png().toFile(path.join(folder, 'ic_launcher_background.png'));
  await sharp('assets/brand.svg').resize(Math.round(48 * scale)).png().toFile(path.join(folder, 'ic_launcher.png'));
}
console.log('Generated iOS and Android app icon assets.');
