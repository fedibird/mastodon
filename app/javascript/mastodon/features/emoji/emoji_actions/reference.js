// Typed emoji references shared by the actions menu, mute settings, and
// detail column. Identity matches the P1/P2 server contract: finished Unicode
// native, local custom_emoji_id, or remote domain+shortcode.

export const DEFAULT_MUTE_REPLACEMENT = '［絵文字］';

export const DEFAULT_MUTE_EFFECTS = Object.freeze({
  replace_in_text: true,
  reject_reactions_to_own_posts: true,
  hide_reactions: true,
  hide_in_picker: true,
});

const read = (value, key) => {
  if (!value) {
    return undefined;
  }

  return typeof value.get === 'function' ? value.get(key) : value[key];
};

export function normalizeReference(input) {
  if (!input || typeof input !== 'object') {
    return null;
  }

  const kind = read(input, 'kind');

  if (kind === 'unicode') {
    const native = read(input, 'native');

    if (typeof native !== 'string' || native === '') {
      return null;
    }

    return { kind: 'unicode', native };
  }

  if (kind !== 'custom') {
    return null;
  }

  const scope = read(input, 'scope') || (read(input, 'domain') ? 'remote' : 'local');

  if (scope === 'remote') {
    const domain = read(input, 'domain');
    const shortcode = read(input, 'shortcode');

    if (typeof domain !== 'string' || domain === '' || typeof shortcode !== 'string' || shortcode === '') {
      return null;
    }

    return { kind: 'custom', scope: 'remote', domain, shortcode };
  }

  const customEmojiId = read(input, 'custom_emoji_id');
  const shortcode = read(input, 'shortcode');

  if ((customEmojiId === null || customEmojiId === undefined || customEmojiId === '') && (!shortcode || shortcode === '')) {
    return null;
  }

  const reference = { kind: 'custom', scope: 'local' };

  if (customEmojiId !== null && customEmojiId !== undefined && customEmojiId !== '') {
    reference.custom_emoji_id = String(customEmojiId);
  }

  if (typeof shortcode === 'string' && shortcode !== '') {
    reference.shortcode = shortcode;
  }

  return reference;
}

export function referencesEqual(left, right) {
  const a = normalizeReference(left);
  const b = normalizeReference(right);

  if (!a || !b || a.kind !== b.kind) {
    return false;
  }

  if (a.kind === 'unicode') {
    return a.native === b.native;
  }

  if (a.scope !== b.scope) {
    return false;
  }

  if (a.scope === 'local') {
    if (a.custom_emoji_id && b.custom_emoji_id) {
      return a.custom_emoji_id === b.custom_emoji_id;
    }

    return Boolean(a.shortcode) && a.shortcode === b.shortcode;
  }

  return a.domain === b.domain && a.shortcode === b.shortcode;
}

export function findMuteForReference(rules, reference) {
  const list = Array.isArray(rules) ? rules : [];

  return list.find(rule => referencesEqual(read(rule, 'emoji'), reference)) || null;
}

export function referenceLabel(reference, detail) {
  const normalized = normalizeReference(reference);

  if (!normalized) {
    return '';
  }

  if (normalized.kind === 'unicode') {
    return normalized.native;
  }

  if (normalized.scope === 'remote') {
    return `:${normalized.shortcode}@${normalized.domain}:`;
  }

  const shortcode = normalized.shortcode || read(detail, 'shortcode');

  return shortcode ? `:${shortcode}:` : `id:${normalized.custom_emoji_id}`;
}

export function identityKey(reference) {
  const normalized = normalizeReference(reference);

  if (!normalized) {
    return null;
  }

  if (normalized.kind === 'unicode') {
    return `u:${normalized.native}`;
  }

  if (normalized.scope === 'local') {
    return `l:${normalized.custom_emoji_id || normalized.shortcode}`;
  }

  return `r:${normalized.domain}:${normalized.shortcode}`;
}

// Build a reference from a reaction chip / cache group. Prefer part.identity
// when present so same-name local and remote reactions stay distinct.
export function referenceFromReaction(emojiReaction) {
  if (!emojiReaction) {
    return null;
  }

  const parts = read(emojiReaction, 'parts');
  const firstPart = parts && (typeof parts.get === 'function' ? parts.get(0) : parts[0]);
  const identity = firstPart ? read(firstPart, 'identity') : null;

  if (identity) {
    return normalizeReference(identity);
  }

  const domain = read(emojiReaction, 'domain');
  const name = read(emojiReaction, 'name');
  const customEmojiId = read(emojiReaction, 'custom_emoji_id')
    || (firstPart && read(firstPart, 'custom_emoji_id'));

  if (domain) {
    return normalizeReference({ kind: 'custom', scope: 'remote', domain, shortcode: name });
  }

  if (customEmojiId) {
    return normalizeReference({ kind: 'custom', scope: 'local', custom_emoji_id: customEmojiId, shortcode: name });
  }

  if (typeof name === 'string' && name !== '') {
    // Reaction names for Unicode are the native string; custom without a
    // domain or id is treated as a local shortcode for resolve to pin.
    if (/^[\w+-]+$/.test(name) && !/\p{Extended_Pictographic}/u.test(name)) {
      return normalizeReference({ kind: 'custom', scope: 'local', shortcode: name });
    }

    return normalizeReference({ kind: 'unicode', native: name });
  }

  return null;
}

export function referenceFromStockItem(item) {
  if (!item) {
    return null;
  }

  if (item.reference) {
    return normalizeReference(item.reference);
  }

  const selection = item.selection || {};

  if (selection.custom) {
    return normalizeReference({
      kind: 'custom',
      scope: 'local',
      custom_emoji_id: selection.custom_emoji_id || item.custom_emoji_id,
      shortcode: (selection.colons || '').replace(/^:|:$/g, '') || selection.id,
    });
  }

  if (selection.native) {
    return normalizeReference({ kind: 'unicode', native: selection.native });
  }

  return null;
}

export function referenceFromPickerEmoji(emoji) {
  if (!emoji) {
    return null;
  }

  if (emoji.custom || emoji.colons) {
    const shortcode = (emoji.colons || '').replace(/^:|:$/g, '') || emoji.id;
    const domain = emoji.domain || null;

    if (domain) {
      return normalizeReference({ kind: 'custom', scope: 'remote', domain, shortcode });
    }

    if (emoji.custom_emoji_id) {
      return normalizeReference({ kind: 'custom', scope: 'local', custom_emoji_id: emoji.custom_emoji_id, shortcode });
    }

    return normalizeReference({ kind: 'custom', scope: 'local', shortcode });
  }

  if (emoji.native) {
    return normalizeReference({ kind: 'unicode', native: emoji.native });
  }

  return null;
}

export function detailPathForReference(reference) {
  const normalized = normalizeReference(reference);

  if (!normalized) {
    return null;
  }

  if (normalized.kind === 'unicode') {
    return `/emoji_detail/unicode/${encodeURIComponent(normalized.native)}`;
  }

  if (normalized.scope === 'remote') {
    return `/emoji_detail/${encodeURIComponent(normalized.shortcode)}@${encodeURIComponent(normalized.domain)}`;
  }

  return `/emoji_detail/${encodeURIComponent(normalized.shortcode || normalized.custom_emoji_id)}`;
}

export function referenceFromDataset(dataset) {
  if (!dataset) {
    return null;
  }

  return normalizeReference({
    kind: dataset.emojiKind || dataset.emoji_kind,
    native: dataset.emojiNative || dataset.emoji_native,
    scope: dataset.emojiScope || dataset.emoji_scope,
    custom_emoji_id: dataset.emojiCustomEmojiId || dataset.emoji_custom_emoji_id,
    domain: dataset.emojiDomain || dataset.emoji_domain,
    shortcode: dataset.emojiShortcode || dataset.emoji_shortcode,
  });
}

export function datasetFromReference(reference) {
  const normalized = normalizeReference(reference);

  if (!normalized) {
    return {};
  }

  if (normalized.kind === 'unicode') {
    return {
      emojiKind: 'unicode',
      emojiNative: normalized.native,
    };
  }

  if (normalized.scope === 'remote') {
    return {
      emojiKind: 'custom',
      emojiScope: 'remote',
      emojiDomain: normalized.domain,
      emojiShortcode: normalized.shortcode,
    };
  }

  return {
    emojiKind: 'custom',
    emojiScope: 'local',
    emojiCustomEmojiId: normalized.custom_emoji_id || '',
    emojiShortcode: normalized.shortcode || '',
  };
}
