// Regenerate the original icon with Xcode's native macOS icon compiler.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.join(root, 'Resources/AppIcon');
const output = path.join(root, 'Resources/ApplicationIcons');
const work = path.join(root, 'build/ApplicationIcons.noindex');
const original = path.join(source, 'macaron-original-mark.png');
// The original icon keeps the outlined mark. The installed OneAgentIcon.icon is a
// separate full-color mark so system notifications stay readable; macOS derives adaptive appearances.
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

{
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
}
