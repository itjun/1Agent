// Regenerate the original default and ten approved alternatives with Xcode's native macOS icon compiler.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.join(root, 'Resources/AppIcon');
const output = path.join(root, 'Resources/ApplicationIcons');
const work = path.join(root, 'build/ApplicationIcons.noindex');
const original = path.join(source, 'macaron-original-mark.png');
const palettes = JSON.parse(fs.readFileSync(path.join(source, 'macaron-palettes.json'), 'utf8'));
// Flat macaron icons keep the original outlined mark. The installed AppIcon.icon is a
// separate outline glyph so Dark, Clear, and Tinted stay readable, and this script must not overwrite it.
const template = {
  fill: { solid: 'srgb:1.00000,1.00000,1.00000,1.00000' },
  groups: [{
    layers: [{
      glass: false,
      'image-name': 'ghostty-mark.png',
      name: 'ghostty-mark',
      position: { scale: 1, 'translation-in-points': [0, 0] },
    }],
    shadow: { kind: 'neutral', opacity: 0.2 },
    translucency: { enabled: false, value: 0 },
  }],
  'supported-platforms': { circles: ['watchOS'], squares: 'shared' },
};
const rgb = hex => hex.match(/[\da-f]{2}/gi).map(value => parseInt(value, 16));
const run = (command, args) => execFileSync(command, args, {
  encoding: 'utf8', env: { ...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' },
});
fs.mkdirSync(output, { recursive: true });

function compileIcon(iconDir, id, icon) {
  const compiled = path.join(work, `${id}-compiled`);
  fs.mkdirSync(compiled, { recursive: true });
  fs.writeFileSync(path.join(iconDir, 'icon.json'), JSON.stringify(icon, null, 2) + '\n');
  run('xcrun', ['actool', iconDir, '--compile', compiled, '--platform', 'macosx', '--minimum-deployment-target', '14.0', '--target-device', 'mac', '--app-icon', id, '--output-partial-info-plist', path.join(compiled, 'Info.plist')]);
  fs.copyFileSync(path.join(compiled, `${id}.icns`), path.join(output, `${id}.icns`));
}

// The bundled default always uses the untouched original mark on a white background.
const originalIconDir = path.join(work, 'Original.icon');
fs.mkdirSync(path.join(originalIconDir, 'Assets'), { recursive: true });
fs.copyFileSync(original, path.join(originalIconDir, 'Assets/ghostty-mark.png'));
const originalIcon = structuredClone(template);
originalIcon.fill.solid = 'srgb:1.00000,1.00000,1.00000,1.00000';
compileIcon(originalIconDir, 'Original', originalIcon);
const square = path.join(source, 'goose-agent-icon-1024.png');
const rounded = path.join(source, 'goose-agent-icon-rounded.png');
run('magick', ['-size', '1024x1024', 'xc:#FFFFFF', original, '-composite', square]);
run('magick', [square, '(', rounded, '-alpha', 'extract', ')', '-alpha', 'off', '-compose', 'CopyOpacity', '-composite', rounded]);
fs.writeFileSync(path.join(source, 'goose-agent-icon.svg'), `<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
  <rect width="1024" height="1024" fill="#FFFFFF"/>
  <image href="ghostty-source.svg" x="152" y="152" width="720" height="720"
         preserveAspectRatio="xMidYMid meet"/>
</svg>
`);
console.log('Original: white and blue default restored; original mark unchanged');

for (const palette of palettes) {
  const ink = rgb(palette.ink), fill = rgb(palette.fill), ring = rgb(palette.ring);
  // Map the original black/blue/white colors; leave alpha and geometry untouched.
  const rows = ink.map((value, index) => {
    const whiteDelta = (fill[index] - value) / 255;
    const blueDelta = (ring[index] - value) / 255;
    return [(243 * whiteDelta - 255 * blueDelta) / 190, 0, (-53 * whiteDelta + 255 * blueDelta) / 190, 0, 0, value / 255];
  });
  const matrix = [...rows, [0,0,0,1,0,0], [0,0,0,0,1,0], [0,0,0,0,0,1]].flat().map(value => value.toFixed(9)).join(' ');
  const iconDir = path.join(work, `${palette.id}.icon`);
  fs.mkdirSync(path.join(iconDir, 'Assets'), { recursive: true });
  const mark = path.join(iconDir, 'Assets/ghostty-mark.png');
  run('magick', [original, '-color-matrix', matrix, '-depth', '8', mark]);
  const alphaDiff = run('magick', ['(', original, '-alpha', 'extract', ')', '(', mark, '-alpha', 'extract', ')', '-metric', 'AE', '-compare', '-format', '%[distortion]', 'info:']).trim();
  if (alphaDiff !== '0') throw new Error(`${palette.id}: original silhouette changed`);
  const icon = structuredClone(template);
  icon.fill.solid = `srgb:${rgb(palette.bg).map(value => (value / 255).toFixed(5)).join(',')},1.00000`;
  compileIcon(iconDir, palette.id, icon);
  console.log(`${palette.id}: native icon generated; silhouette unchanged`);
}
