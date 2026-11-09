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

const asArray = value => {
  if (!value) {
    return [];
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

// Local identity is the database id. A shortcode alone is not enough: deleting
// a row and re-registering the same shortcode creates a different emoji.
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
    if (!a.custom_emoji_id || !b.custom_emoji_id) {
      return false;
    }

    return a.custom_emoji_id === b.custom_emoji_id;
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
    return normalized.custom_emoji_id ? `l:${normalized.custom_emoji_id}` : null;
  }

  return `r:${normalized.domain}:${normalized.shortcode}`;
}

const partCustomEmojiId = part => {
  const direct = read(part, 'custom_emoji_id');

  if (direct !== null && direct !== undefined && direct !== '') {
    return String(direct);
  }

  const fromIdentity = read(read(part, 'identity'), 'custom_emoji_id');

  return fromIdentity !== null && fromIdentity !== undefined && fromIdentity !== ''
    ? String(fromIdentity)
    : null;
};

// Public reaction groups use the minimum custom_emoji_id as the representative
// image. parts stay in created_at order, so parts[0] is not the display identity.
export function representativeReactionPart(emojiReaction) {
  const parts = asArray(read(emojiReaction, 'parts'));

  if (parts.length === 0) {
    return null;
  }

  if (parts.length === 1) {
    return parts[0];
  }

  const groupDomain = read(emojiReaction, 'domain');
  const groupUrl = read(emojiReaction, 'url');

  const byDisplay = parts.find(part => {
    const url = read(part, 'url');
    const domain = read(part, 'domain');

    if (groupUrl && url && url === groupUrl) {
      return true;
    }

    return Boolean(groupDomain && domain && domain === groupDomain);
  });

  if (byDisplay) {
    return byDisplay;
  }

  const withIds = parts.filter(part => partCustomEmojiId(part));

  if (withIds.length === 0) {
    return parts[0];
  }

  return withIds.reduce((best, part) => {
    const id = Number(partCustomEmojiId(part));
    const bestId = Number(partCustomEmojiId(best));

    return id < bestId ? part : best;
  });
}

// Build a reference from a reaction chip / cache group. Prefer the display
// representative so same-name local and remote reactions stay distinct.
export function referenceFromReaction(emojiReaction) {
  if (!emojiReaction) {
    return null;
  }

  const part = representativeReactionPart(emojiReaction);
  const identity = part ? read(part, 'identity') : null;

  if (identity) {
    return normalizeReference(identity);
  }

  const domain = read(emojiReaction, 'domain') || (part && read(part, 'domain'));
  const name = read(emojiReaction, 'name');
  const customEmojiId = read(emojiReaction, 'custom_emoji_id') || (part && partCustomEmojiId(part));

  if (domain) {
    return normalizeReference({ kind: 'custom', scope: 'remote', domain, shortcode: name });
  }

  if (customEmojiId) {
    return normalizeReference({ kind: 'custom', scope: 'local', custom_emoji_id: customEmojiId, shortcode: name });
  }

  if (typeof name === 'string' && name !== '') {
    // Without a part identity or id, a custom shortcode alone is unresolved.
    // Only finished Unicode natives are safe to treat as identity here.
    if (/^[\w+-]+$/.test(name) && !/\p{Extended_Pictographic}/u.test(name)) {
      return null;
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

  if (emoji.custom) {
    const shortcode = (emoji.colons || '').replace(/^:|:$/g, '') || emoji.id;
    const domain = emoji.domain || null;

    if (domain) {
      return normalizeReference({ kind: 'custom', scope: 'remote', domain, shortcode });
    }

    if (emoji.custom_emoji_id) {
      return normalizeReference({ kind: 'custom', scope: 'local', custom_emoji_id: emoji.custom_emoji_id, shortcode });
    }

    // Custom without a stable id stays unresolved until resolve pins one.
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

// Clipboard payload for the shared menu. Remote custom never copies.
// Local needs a concrete shortcode (from the reference or a resolve payload).
export function copyTextForReference(reference, resolved = null) {
  const normalized = normalizeReference(reference);

  if (!normalized) {
    return null;
  }

  if (normalized.kind === 'unicode') {
    return normalized.native;
  }

  if (normalized.scope === 'remote') {
    return null;
  }

  const resolvedReference = normalizeReference(resolved && (resolved.reference || resolved));
  const shortcode = normalized.shortcode
    || (resolvedReference && resolvedReference.scope === 'local' && resolvedReference.shortcode)
    || null;

  if (!shortcode) {
    return null;
  }

  return `:${shortcode}:`;
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
