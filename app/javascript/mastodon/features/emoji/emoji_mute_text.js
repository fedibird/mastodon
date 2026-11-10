// Display-only projection for emoji mute effect `replace_in_text`.
//
// Status HTML stays the shared, viewer-independent string produced by
// emojify (`contentHtml`, `spoilerHtml`, translation HTML). This module
// returns a new string for the screen. It does not write the status store,
// re-run emojify, or interpret the replacement as HTML.
//
// Identity matches the P2 contract:
// - Unicode: the whole `alt` sequence, including skin tone, ZWJ, and VS.
// - Local custom: `emojis[].id` for an img whose `data-domain` is empty.
//   A shortcode with no id, or two different ids, is not replaced.
// - Remote custom: `data-domain` + `data-shortcode` on the img. The cache
//   row id is not the identity.
//
// `data-domain` is the author domain emojify stored, which is the domain
// `CustomEmoji.from_text` used. A missing `data-domain` or `data-shortcode`
// is unresolved and is left alone.
//
// The signed-in WebUI applies the latest mute document held in Redux. Before
// that document arrives, and again while a stream revision is still being
// fetched, the previous document stays on screen. The server does not filter
// shared post HTML, so a mute created in that gap can remain visible until
// the GET lands. A failed GET keeps the last applied document.

import { identityKey } from './emoji_actions/reference';

const CACHE_LIMIT = 400;

const INACTIVE_INDEX = Object.freeze({
  signature: 'none',
  active: false,
  replacements: new Map(),
});

let cachedRules = null;
let cachedIndex = INACTIVE_INDEX;
let cacheSignature = INACTIVE_INDEX.signature;
let cache = new Map();
let parseCount = 0;

const read = (value, key) => {
  if (!value) {
    return undefined;
  }

  return typeof value.get === 'function' ? value.get(key) : value[key];
};

const asArray = value => {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value;
  }

  if (typeof value.toArray === 'function') {
    return value.toArray();
  }

  if (typeof value.size === 'number' && typeof value.get === 'function') {
    const list = [];

    for (let index = 0; index < value.size; index += 1) {
      list.push(value.get(index));
    }

    return list;
  }

  return Array.from(value);
};

const replacementText = rule => {
  const value = read(rule, 'replacement');

  return typeof value === 'string' ? value : '';
};

export function buildReplaceInTextIndex(rules) {
  const lines = [];
  const replacements = new Map();

  asArray(rules).forEach(rule => {
    if (read(read(rule, 'effects'), 'replace_in_text') !== true) {
      return;
    }

    const key = identityKey(read(rule, 'emoji'));

    if (!key || replacements.has(key)) {
      return;
    }

    const text = replacementText(rule);
    replacements.set(key, text);
    lines.push(JSON.stringify([key, text]));
  });

  if (replacements.size === 0) {
    return INACTIVE_INDEX;
  }

  lines.sort();

  return {
    signature: lines.join('\n'),
    active: true,
    replacements,
  };
}

// Same object while the replace_in_text signature is unchanged, so a
// PureComponent can skip a render when only hide_reactions changes.
export function replaceInTextIndexFromRules(rules) {
  if (rules === cachedRules) {
    return cachedIndex;
  }

  const next = buildReplaceInTextIndex(rules);
  cachedRules = rules;

  if (!next.active) {
    cachedIndex = INACTIVE_INDEX;
    return cachedIndex;
  }

  if (cachedIndex.active && cachedIndex.signature === next.signature) {
    return cachedIndex;
  }

  cachedIndex = next;
  return cachedIndex;
}

const emojiSignature = emojis => {
  const parts = [];

  asArray(emojis).forEach(emoji => {
    const shortcode = read(emoji, 'shortcode');
    const domain = read(emoji, 'domain') || '';
    const id = read(emoji, 'id');

    if (typeof shortcode !== 'string' || shortcode === '') {
      return;
    }

    parts.push(JSON.stringify([shortcode, domain, id === null || id === undefined ? '' : String(id)]));
  });

  parts.sort();
  return parts.join('\n');
};

// shortcode -> id, or null when two local rows share the shortcode.
const localIdsByShortcode = emojis => {
  const map = new Map();

  asArray(emojis).forEach(emoji => {
    const domain = read(emoji, 'domain');

    if (domain !== null && domain !== undefined && domain !== '') {
      return;
    }

    const shortcode = read(emoji, 'shortcode');
    const id = read(emoji, 'id');

    if (typeof shortcode !== 'string' || shortcode === '' || id === null || id === undefined || id === '') {
      return;
    }

    const value = String(id);
    const current = map.get(shortcode);

    if (current === undefined) {
      map.set(shortcode, value);
    } else if (current !== value) {
      map.set(shortcode, null);
    }
  });

  return map;
};

const mappedReplacement = (index, reference) => {
  const key = identityKey(reference);

  if (!key || !index.replacements.has(key)) {
    return undefined;
  }

  return index.replacements.get(key);
};

const replacementForImage = (img, index, localIds) => {
  if (!img.classList.contains('custom-emoji')) {
    const native = img.getAttribute('alt');

    if (typeof native !== 'string' || native === '') {
      return undefined;
    }

    return mappedReplacement(index, { kind: 'unicode', native });
  }

  if (!img.hasAttribute('data-shortcode') || !img.hasAttribute('data-domain')) {
    return undefined;
  }

  const shortcode = img.getAttribute('data-shortcode') || '';
  const domain = img.getAttribute('data-domain') || '';

  if (shortcode === '') {
    return undefined;
  }

  if (domain !== '') {
    return mappedReplacement(index, { kind: 'custom', scope: 'remote', domain, shortcode });
  }

  const id = localIds.get(shortcode);

  if (!id) {
    return undefined;
  }

  return mappedReplacement(index, { kind: 'custom', scope: 'local', custom_emoji_id: id, shortcode });
};

const replaceNode = (node, text) => {
  const parent = node.parentNode;

  if (!parent) {
    return;
  }

  if (text === '') {
    parent.removeChild(node);
    return;
  }

  parent.replaceChild(node.ownerDocument.createTextNode(text), node);
};

const transformHtml = (html, emojis, index) => {
  parseCount += 1;
  const template = document.createElement('template');
  template.innerHTML = html;
  const localIds = localIdsByShortcode(emojis);
  const images = template.content.querySelectorAll('img.emojione');
  let changed = false;

  for (let indexInHtml = 0; indexInHtml < images.length; indexInHtml += 1) {
    const img = images[indexInHtml];

    if (!img.parentNode) {
      continue;
    }

    const replacement = replacementForImage(img, index, localIds);

    if (replacement === undefined) {
      continue;
    }

    const target = img.parentElement && img.parentElement.tagName === 'PICTURE' ? img.parentElement : img;
    replaceNode(target, replacement);
    changed = true;
  }

  if (!changed) {
    return html;
  }

  const holder = document.createElement('div');
  holder.appendChild(template.content);
  return holder.innerHTML;
};

export function replaceEmojiInDisplayHtml(html, emojis, index) {
  if (!index || index.active !== true || typeof html !== 'string' || html.indexOf('emojione') === -1) {
    return html;
  }

  if (cacheSignature !== index.signature) {
    cache = new Map();
    cacheSignature = index.signature;
  }

  const key = `${emojiSignature(emojis)}\n${html}`;
  const stored = cache.get(key);

  if (stored !== undefined) {
    return stored;
  }

  const next = transformHtml(html, emojis, index);
  cache.set(key, next);

  if (cache.size > CACHE_LIMIT) {
    cache.delete(cache.keys().next().value);
  }

  return next;
}

export function resetEmojiMuteTextForTests() {
  cachedRules = null;
  cachedIndex = INACTIVE_INDEX;
  cacheSignature = INACTIVE_INDEX.signature;
  cache = new Map();
  parseCount = 0;
}

export function emojiMuteTextParseCount() {
  return parseCount;
}
