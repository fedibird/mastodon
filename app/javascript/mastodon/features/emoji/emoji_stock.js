import Graphemer from 'graphemer';

const graphemes = new Graphemer();

// Resolved personal-emoji stock shared by the picker and its supply adapter.
// This is an in-memory contract for the picker, not a persistence schema
// or a public API. Suppliers fill every field the picker needs so rendering,
// search, and selection never consult the full Unicode catalog, the standard
// Nimble dataset, or the custom-emoji index.

/**
 * One registered category. `id` is stable and is not an emoji id.
 * `items` stays in registration order.
 *
 * @typedef {Object} EmojiStockCategory
 * @property {string} id
 * @property {string} name
 * @property {{text: string, image?: EmojiStockImage}} [heading] Resolved before filtering.
 * @property {EmojiStockItem[]} items
 */

/**
 * Image data that is already safe to render. `src` is an individual SVG or
 * a custom image URL, never a coordinate into the standard sprite sheet.
 *
 * @typedef {Object} EmojiStockImage
 * @property {string} src
 * @property {string} [animatedSrc]
 * @property {string} alt
 * @property {string} [title]
 * @property {number} [width] Original image dimensions, when available.
 * @property {number} [height]
 */

/**
 * Values handed to the existing `(emoji, event)` callback.
 * `id` is the canonical emoji id. It is never the stock row key or the
 * category id. `native` is the finished Unicode string, including skin
 * tone, ZWJ, and variation selectors, or the custom colon form.
 *
 * @typedef {Object} EmojiStockSelection
 * @property {string} id
 * @property {boolean} custom
 * @property {string} [native]
 * @property {string} [colons]
 */

/**
 * One placed emoji. `key` identifies the placement so the same canonical
 * emoji can appear in more than one category, and so two skin tones of the
 * same canonical id stay distinct.
 *
 * @typedef {Object} EmojiStockItem
 * @property {string} key
 * @property {string} label
 * @property {EmojiStockImage} image
 * @property {string[]} search Display name, shortcode, reading, and aliases.
 * @property {EmojiStockSelection} selection
 */

/**
 * @typedef {Object} EmojiStock
 * @property {EmojiStockCategory[]} categories Registration order.
 */

/**
 * Successful empty stock uses `ready`. It is not an error.
 *
 * @typedef {Object} EmojiStockLoad
 * @property {'ready'|'error'} status
 * @property {EmojiStock} [stock]
 * @property {Error} [error]
 */

export function emptyEmojiStock() {
  return { categories: [] };
}

// The persisted name stays unchanged. Modern engines use the Unicode grapheme
// boundary algorithm; Graphemer supplies it on engines without Intl.Segmenter,
// without loading the emoji catalog (including Japanese combining marks).
export function firstGrapheme(value) {
  const text = typeof value === 'string' ? value : '';

  if (typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function') {
    const iterator = new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)[Symbol.iterator]();
    const first = iterator.next();

    return first.done ? '' : first.value.segment;
  }

  return graphemes.iterateGraphemes(text).next().value || '';
}

export function isEmptyEmojiStock(stock) {
  const categories = stock && Array.isArray(stock.categories) ? stock.categories : [];

  return categories.every(category => !category || !Array.isArray(category.items) || category.items.length === 0);
}

// Matching only. Selection strings are copied unchanged.
export function normalizeSearchKey(value) {
  const text = value === null || value === undefined ? '' : String(value);

  return text.normalize('NFKC').toLocaleLowerCase().replace(/\s+/g, '');
}

function searchFields(item) {
  const fields = [];

  if (item && item.label) {
    fields.push(item.label);
  }

  if (item && Array.isArray(item.search)) {
    item.search.forEach(term => {
      if (term !== null && term !== undefined && term !== '') {
        fields.push(term);
      }
    });
  }

  const selection = item && item.selection;

  if (selection) {
    if (selection.id) {
      fields.push(selection.id);
    }

    if (selection.colons) {
      fields.push(selection.colons);
    }

    if (selection.native) {
      fields.push(selection.native);
    }
  }

  return fields;
}

function itemMatches(item, normalizedQuery) {
  return searchFields(item).some(field => normalizeSearchKey(field).includes(normalizedQuery));
}

// New category and item arrays, same item objects. Order is kept.
// An empty query does not sort or drop categories.
export function searchEmojiStock(stock, query) {
  const source = stock && Array.isArray(stock.categories) ? stock.categories : [];
  const normalized = normalizeSearchKey(query);
  const categories = [];

  source.forEach(category => {
    const items = category && Array.isArray(category.items) ? category.items : [];
    const visible = normalized ? items.filter(item => itemMatches(item, normalized)) : items.slice();

    if (normalized && visible.length === 0) {
      return;
    }

    categories.push({
      ...category,
      items: visible,
    });
  });

  return { categories };
}

/**
 * New object for one callback notification.
 * Existing handlers may assign `native` from `colons`; that write stays on
 * this object. The stock item and any other placement of the same emoji
 * keep the supplier's strings.
 */
export function toEmojiPickerCallbackPayload(item) {
  const selection = item && item.selection ? item.selection : {};
  const custom = selection.custom === true;
  const payload = {
    id: selection.id,
    custom,
    native: selection.native,
  };

  if (custom) {
    payload.colons = selection.colons;

    if (payload.native === null || payload.native === undefined || payload.native === '') {
      payload.native = selection.colons;
    }
  }

  return payload;
}

export function normalizeEmojiStockLoad(result) {
  if (!result || result.status === 'error') {
    const error = result && result.error instanceof Error ? result.error : new Error('Emoji stock failed to load');

    return { status: 'error', error };
  }

  if (result.status !== 'ready') {
    return { status: 'error', error: new Error('Emoji stock load status is missing') };
  }

  const stock = result.stock && Array.isArray(result.stock.categories) ? result.stock : emptyEmojiStock();

  return { status: 'ready', stock };
}
