import {
  appliedEmojiMuteRevision,
  currentEmojiMutes,
  emojiMuteAuthorizationFailure,
  emojiMuteDocumentReady,
  loadEmojiMutes,
  observedEmojiMuteRevision,
  subscribeEmojiMuteDocument,
} from './emoji_mute_store';
import { identityKey, referenceFromStockItem } from './emoji_actions/reference';

// Candidate exclusion for hide_in_picker only. The other three effects never
// add or remove a picker candidate. The Nimble catalog, personal stock, and
// frequently-used counters stay intact; callers render a derived list.
//
// Paths that do not render through EmojiPickerShell are not filtered here.
// C1 records them and leaves them for C2:
// - compose autosuggest (`actions/compose.js` emojiSearch)
// - reaction-history filter (`emoji_filter_picker.js`)
// - saved mute grid in emoji mute settings (management list; kept on purpose)

const UNRESOLVED_LIMIT = 50;
const unresolved = new Set();
const stockProjections = new WeakMap();
const HELD_STOCK = Object.freeze({ categories: [] });

let cached = null;

// Counts full index builds. Repeated renders with the same document stay at
// the same count.
export const emojiPickerIndexProbe = { builds: 0 };

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

  return Array.from(value);
};

export function noteUnresolvedPickerCandidate(kind, detail) {
  if (unresolved.size >= UNRESOLVED_LIMIT) {
    return;
  }

  unresolved.add(`${kind}:${detail || 'unknown'}`);
}

function recordUnresolved(kind, detail) {
  noteUnresolvedPickerCandidate(kind, detail);
}

export function unresolvedPickerCandidates() {
  return Array.from(unresolved);
}

export function resetUnresolvedPickerCandidatesForTests() {
  unresolved.clear();
}

function hideKeys(rules) {
  emojiPickerIndexProbe.builds += 1;
  const keys = [];

  asArray(rules).forEach(rule => {
    if (read(read(rule, 'effects'), 'hide_in_picker') !== true) {
      return;
    }

    const key = identityKey(read(rule, 'emoji'));

    if (key) {
      keys.push(key);
    }
  });

  keys.sort();
  return keys;
}

function buildVisibility() {
  const ready = emojiMuteDocumentReady();
  const revision = appliedEmojiMuteRevision();
  const observed = observedEmojiMuteRevision();
  const failure = emojiMuteAuthorizationFailure();
  const rules = ready ? currentEmojiMutes() : null;

  if (cached && cached.ready === ready && cached.revision === revision && cached.observed === observed && cached.failure === failure && cached.rules === rules) {
    return cached;
  }

  const keys = ready ? hideKeys(rules) : [];
  const signature = ready
    ? `${revision}:${keys.join('\n')}`
    : `held:${failure || 'pending'}:${observed || ''}`;

  cached = {
    ready,
    signature,
    revision,
    observed,
    failure,
    rules,
    index: new Set(keys),
  };

  return cached;
}

export function emojiPickerVisibility() {
  return buildVisibility();
}

export function subscribeEmojiPickerVisibility(listener) {
  return subscribeEmojiMuteDocument(() => {
    cached = null;
    listener();
  });
}

export function emojiPickerCandidateHidden(reference, visibility = emojiPickerVisibility()) {
  if (!visibility.ready) {
    return true;
  }

  const key = identityKey(reference);

  if (!key) {
    recordUnresolved('reference', reference && reference.kind);
    return false;
  }

  return visibility.index.has(key);
}

function stockItemHidden(item, visibility) {
  const reference = referenceFromStockItem(item);

  if (!reference || !identityKey(reference)) {
    recordUnresolved('stock', item && item.key);
    return false;
  }

  return emojiPickerCandidateHidden(reference, visibility);
}

function projectHeading(category, visibility) {
  const heading = category && category.heading;

  if (!heading || !heading.image) {
    return heading;
  }

  const key = identityKey(heading.reference);

  // A shared SVG or alt string is not an identity. Without the saved
  // reference, the representative is ambiguous and the name is the heading.
  if (!key) {
    recordUnresolved('heading', category && category.id);
    return { text: (category && category.name) || heading.text || '' };
  }

  if (visibility.index.has(key)) {
    return { text: (category && category.name) || heading.text || '' };
  }

  return heading;
}

function projectCategory(category, visibility) {
  const sourceItems = category && Array.isArray(category.items) ? category.items : [];
  const items = sourceItems.filter(item => !stockItemHidden(item, visibility));
  const heading = projectHeading(category, visibility);

  if (items.length === sourceItems.length && heading === (category && category.heading)) {
    return category;
  }

  return {
    ...category,
    heading,
    items,
  };
}

export function projectEmojiStockForPicker(stock, visibility = emojiPickerVisibility()) {
  if (!visibility.ready) {
    return { stock: HELD_STOCK, held: true };
  }

  if (!stock || !Array.isArray(stock.categories)) {
    return { stock: stock && stock.categories ? stock : { categories: [] }, held: false };
  }

  const hit = stockProjections.get(stock);

  if (hit && hit.signature === visibility.signature) {
    return hit.value;
  }

  let changed = false;
  const categories = stock.categories.map(category => {
    const next = projectCategory(category || { items: [] }, visibility);

    if (next !== category) {
      changed = true;
    }

    return next;
  });
  const projected = changed ? { ...stock, categories } : stock;
  const value = { stock: projected, held: false };

  stockProjections.set(stock, { signature: visibility.signature, value });
  return value;
}

export function ensureEmojiPickerMuteDocument() {
  if (emojiMuteDocumentReady()) {
    return Promise.resolve(currentEmojiMutes());
  }

  return loadEmojiMutes();
}
