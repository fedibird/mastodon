// Display-only projection for emoji mute effect `replace_in_text`.
//
// Status HTML stays the shared, viewer-independent string produced by
// emojify (`contentHtml`, `spoilerHtml`, translation HTML). This module
// returns a new string for the screen. It does not write the status store,
// re-run emojify, or interpret the replacement as HTML.
//
// Identity matches the P2 contract and is read from the HTML that emojify
// built, not from a later `emojis` list:
// - Unicode: the whole `alt` sequence, including skin tone, ZWJ, and VS.
// - Local custom: `data-emoji-id` on an img whose `data-domain` is empty.
//   That is the row id at HTML generation. A missing id fails closed.
//   The current shortcode is not an identity.
// - Remote custom: `data-domain` + `data-shortcode` on the img. The cache
//   row id is not the identity.
//
// `data-domain` is the author domain emojify stored, which is the domain
// `CustomEmoji.from_text` used. A missing `data-domain` or `data-shortcode`
// is unresolved and is left alone. HTML saved before `data-emoji-id` existed
// is also left alone, so an old image is not claimed by a reused shortcode.
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
let textCache = new Map();
let textCacheSignature = INACTIVE_INDEX.signature;
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

const mappedReplacement = (index, reference) => {
  const key = identityKey(reference);

  if (!key || !index.replacements.has(key)) {
    return undefined;
  }

  return index.replacements.get(key);
};

const replacementForImage = (img, index) => {
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

  if (!img.hasAttribute('data-emoji-id')) {
    return undefined;
  }

  const id = img.getAttribute('data-emoji-id') || '';

  if (id === '') {
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

const identityHints = img => {
  const alt = img.getAttribute('alt') || '';
  const title = img.getAttribute('title') || '';
  const shortcode = img.getAttribute('data-shortcode') || '';
  const domain = img.getAttribute('data-domain') || '';
  const hints = [alt, title, shortcode, domain];

  if (shortcode) {
    hints.push(`:${shortcode}:`);
  }

  return hints.filter(hint => hint !== '');
};

const attributeNamesEmoji = (value, hints) => hints.some(hint => value.includes(hint));

// A muted image can sit inside the emoji's own link. The link stays so the
// text substitute remains a link, but its title and accessible name must be
// the substitute, not the shortcode or domain.
const scrubMutedEmojiLink = (link, replacement, hints) => {
  if (!link || link.querySelector('img.emojione, img.custom-emoji')) {
    return;
  }

  ['title', 'aria-label', 'aria-labelledby', 'aria-describedby'].forEach(name => {
    const value = link.getAttribute(name) || '';

    if (value && attributeNamesEmoji(value, hints)) {
      link.removeAttribute(name);
    }
  });

  if (!link.classList.contains('custom-emoji-url-link')) {
    return;
  }

  link.removeAttribute('aria-label');
  link.removeAttribute('aria-labelledby');
  link.removeAttribute('aria-describedby');

  if (replacement) {
    link.setAttribute('title', replacement);
    return;
  }

  link.removeAttribute('title');
};

export function mutedEmojiImageRemains(link) {
  return !!(link && link.querySelector('img.emojione, img.custom-emoji'));
}

// Content rewrites link titles after the projection. Do not put the muted
// shortcode or domain back into title or aria-label.
export function retainMutedEmojiLinkLabel(link) {
  if (!link || mutedEmojiImageRemains(link)) {
    return;
  }

  const shortcode = link.getAttribute('data-shortcode') || '';
  const domain = link.getAttribute('data-domain') || '';
  const hints = [shortcode, domain, shortcode ? `:${shortcode}:` : ''].filter(hint => hint !== '');

  ['title', 'aria-label', 'aria-labelledby', 'aria-describedby'].forEach(name => {
    const value = link.getAttribute(name) || '';

    if (value && attributeNamesEmoji(value, hints)) {
      link.removeAttribute(name);
    }
  });

  if (link.getAttribute('title')) {
    return;
  }

  const visible = (link.textContent || '').trim();

  if (visible && !attributeNamesEmoji(visible, hints)) {
    link.setAttribute('title', visible);
  }
}

const transformHtml = (html, index) => {
  parseCount += 1;
  const template = document.createElement('template');
  template.innerHTML = html;
  const images = template.content.querySelectorAll('img.emojione');
  let changed = false;

  for (let indexInHtml = 0; indexInHtml < images.length; indexInHtml += 1) {
    const img = images[indexInHtml];

    if (!img.parentNode) {
      continue;
    }

    const replacement = replacementForImage(img, index);

    if (replacement === undefined) {
      continue;
    }

    const target = img.parentElement && img.parentElement.tagName === 'PICTURE' ? img.parentElement : img;
    const link = target.closest ? target.closest('a') : null;
    const hints = identityHints(img);
    replaceNode(target, replacement);
    scrubMutedEmojiLink(link, replacement, hints);
    changed = true;
  }

  if (!changed) {
    return html;
  }

  const holder = document.createElement('div');
  holder.appendChild(template.content);
  return holder.innerHTML;
};

export function replaceEmojiInDisplayHtml(html, index) {
  if (!index || index.active !== true || typeof html !== 'string' || html.indexOf('emojione') === -1) {
    return html;
  }

  if (cacheSignature !== index.signature) {
    cache = new Map();
    textCache = new Map();
    cacheSignature = index.signature;
    textCacheSignature = index.signature;
  }

  const stored = cache.get(html);

  if (stored !== undefined) {
    return stored;
  }

  const next = transformHtml(html, index);
  cache.set(html, next);

  if (cache.size > CACHE_LIMIT) {
    cache.delete(cache.keys().next().value);
  }

  return next;
}

const visibleText = html => {
  const template = document.createElement('template');
  template.innerHTML = html;
  const parts = [];

  const walk = node => {
    if (node.nodeType === Node.TEXT_NODE) {
      parts.push(node.nodeValue || '');
      return;
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
      return;
    }

    const tag = node.tagName;

    if (tag === 'SCRIPT' || tag === 'STYLE') {
      return;
    }

    // Remaining images were not muted. Alt is the glyph or :shortcode:, never
    // the image URL or the img title (which can repeat a shortcode).
    if (tag === 'IMG') {
      parts.push(node.getAttribute('alt') || '');
      return;
    }

    const children = node.childNodes;

    for (let index = 0; index < children.length; index += 1) {
      walk(children[index]);
    }
  };

  const roots = template.content.childNodes;

  for (let index = 0; index < roots.length; index += 1) {
    walk(roots[index]);
  }

  return parts.join('');
};

// Title and other plain labels stay byte-for-byte the same unless this HTML
// actually replaced a muted emoji. The replacement is read back from the
// presented HTML, so a muted glyph, shortcode, or image URL is not copied
// out of the original plain string.
export function emojiMutedPlainLabel(plain, html, index) {
  if (typeof plain !== 'string') {
    return plain;
  }

  const presented = replaceEmojiInDisplayHtml(html, index);

  if (presented === html || typeof presented !== 'string') {
    return plain;
  }

  const signature = index && index.signature ? index.signature : '';

  if (textCacheSignature !== signature) {
    textCache = new Map();
    textCacheSignature = signature;
  }

  const stored = textCache.get(presented);

  if (stored !== undefined) {
    return stored;
  }

  const text = visibleText(presented);
  textCache.set(presented, text);

  if (textCache.size > CACHE_LIMIT) {
    textCache.delete(textCache.keys().next().value);
  }

  return text;
}

export function resetEmojiMuteTextForTests() {
  cachedRules = null;
  cachedIndex = INACTIVE_INDEX;
  cacheSignature = INACTIVE_INDEX.signature;
  textCacheSignature = INACTIVE_INDEX.signature;
  cache = new Map();
  textCache = new Map();
  parseCount = 0;
}

export function emojiMuteTextParseCount() {
  return parseCount;
}
