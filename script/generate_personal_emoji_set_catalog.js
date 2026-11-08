#!/usr/bin/env node

// Server-only trusted stock metadata, built from the pinned picker sources.
// No network access. Re-run after changing emoji data or Japanese readings.
// --check verifies the tracked file without rewriting it.
const fs = require('fs');
const path = require('path');
const { buildEmojiDatasets, PREVAL_VERSION } = require('../app/javascript/mastodon/features/emoji/emoji_build');
const { unicodeToFilename } = require('../app/javascript/mastodon/features/emoji/unicode_to_filename');

const root = path.resolve(__dirname, '..');
const output = path.join(root, 'config/personal_emoji_set_unicode.json');
const source = fs.readFileSync(path.join(root, 'app/javascript/mastodon/features/emoji/emoji_unicode_ja_readings.js'), 'utf8');
const readings = JSON.parse(source.slice(source.indexOf('export default ') + 'export default '.length).trim().replace(/;$/, '').replace(/,\s*}/g, '}'));
const { unicodeMappingData, nimblePickerData } = buildEmojiDatasets();
const variants = {};
const metadata = {};

function addVariant(id, row) {
  const [native, specialFilename] = row;
  const filename = specialFilename || unicodeToFilename(native);

  if (!/^[a-f0-9]+(?:-[a-f0-9]+)*$/.test(filename) || !fs.existsSync(path.join(root, 'public/emoji', `${filename}.svg`))) {
    throw new Error(`Missing emoji asset: ${filename}`);
  }

  variants[native] = [id, filename];
}

Object.entries(unicodeMappingData.shortCodesToEmojiData).forEach(([id, rows]) => {
  const emoji = nimblePickerData.emojis[id];
  const label = emoji?.name || id;
  const terms = [id, ...(emoji?.short_names || []), ...(emoji?.search || '').split(',')].filter(Boolean);
  const defaultReadings = readings[(emoji?.native || '').replace(/[\uFE0E\uFE0F]/g, '')] || [];

  metadata[id] = [label, Array.from(new Set([...terms, ...defaultReadings]))];
  rows.forEach(row => addVariant(id, row));
});

unicodeMappingData.emojisWithoutShortCodes.forEach(row => {
  const id = `unicode-${row[1] || unicodeToFilename(row[0])}`;
  metadata[id] = [row[0], [id]];
  addVariant(id, row);
});

// Some fully qualified skin variants have no shortcode in the display map
// (for example a detective with a skin tone). Nimble still has the canonical
// identity. Use its exact finished strings without reconstructing modifiers.
Object.entries(nimblePickerData.emojis).forEach(([id, emoji]) => {
  [emoji, ...Object.values(emoji.skin_variations || {})].forEach(variant => {
    if (!variant.native) return;
    const existing = variants[variant.native];
    if (!existing) throw new Error(`Missing picker variant: ${id} ${variant.native}`);
    variants[variant.native] = [id, existing[1]];
  });
});

const usedIds = new Set(Object.values(variants).map(([id]) => id));
Object.keys(metadata).forEach(id => {
  if (!usedIds.has(id)) delete metadata[id];
});

const sorted = object => Object.fromEntries(Object.keys(object).sort().map(key => [key, object[key]]));
const text = JSON.stringify({ version: 1, source_version: PREVAL_VERSION, variants: sorted(variants), metadata: sorted(metadata), readings: sorted(readings) }) + '\n';

if (process.argv.includes('--check')) {
  if (fs.readFileSync(output, 'utf8') !== text) {
    throw new Error('Personal emoji set Unicode catalog is out of date. Run node script/generate_personal_emoji_set_catalog.js');
  }
} else {
  fs.writeFileSync(output, text);
}

process.stdout.write(`Personal emoji set Unicode catalog: ${Object.keys(variants).length} variants verified.\n`);
