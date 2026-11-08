// Viewer projection for emoji-reaction updates.
//
// REST already returns the viewer's groups. Streaming is shared and still
// carries every identity in `parts`. When mute rules are loaded, drop hidden
// identities here so an older or unfiltered event cannot put them back.
// Rules are plain objects or Immutable maps. Text replacement and picker
// exclusion are not applied in this module.

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

  return typeof value.toArray === 'function' ? value.toArray() : Array.from(value);
};

const variationSelectors = /[\uFE0E\uFE0F]/g;

const stripVariation = value => (typeof value === 'string' ? value.replace(variationSelectors, '') : '');

export const unicodeMatches = (stored, reactionName) => {
  if (typeof stored !== 'string' || typeof reactionName !== 'string') {
    return false;
  }

  if (stored === reactionName) {
    return true;
  }

  const left = stripVariation(stored);
  const right = stripVariation(reactionName);

  return left.length > 0 && left === right;
};

const identityOf = part => read(part, 'identity') || {};

const hidesIdentity = (rules, identity) => asArray(rules).some(rule => {
  if (read(read(rule, 'effects'), 'hide_reactions') !== true) {
    return false;
  }

  const emoji = read(rule, 'emoji') || {};
  const kind = read(identity, 'kind');

  if (kind === 'unicode' || (!kind && read(identity, 'native'))) {
    return read(emoji, 'kind') === 'unicode' && unicodeMatches(read(emoji, 'native'), read(identity, 'native'));
  }

  if (read(emoji, 'kind') !== 'custom' || read(emoji, 'scope') !== read(identity, 'scope')) {
    return false;
  }

  if (read(identity, 'scope') === 'local') {
    return String(read(emoji, 'custom_emoji_id')) === String(read(identity, 'custom_emoji_id'));
  }

  return read(identity, 'scope') === 'remote'
    && read(emoji, 'domain') === read(identity, 'domain')
    && read(emoji, 'shortcode') === read(identity, 'shortcode');
});

// Optimistic add/remove only knows the reaction name and domain. A local
// custom mute is an id, so a shortcode alone is not enough to hide it.
export const reactionNameHidden = (name, domain, rules) => asArray(rules).some(rule => {
  if (read(read(rule, 'effects'), 'hide_reactions') !== true) {
    return false;
  }

  const emoji = read(rule, 'emoji') || {};

  if (domain) {
    return read(emoji, 'kind') === 'custom'
      && read(emoji, 'scope') === 'remote'
      && read(emoji, 'domain') === domain
      && read(emoji, 'shortcode') === name;
  }

  return read(emoji, 'kind') === 'unicode' && unicodeMatches(read(emoji, 'native'), name);
});

const partHidden = (part, rules) => hidesIdentity(rules, identityOf(part));

export const projectStreamReaction = (payload, rules) => {
  if (!payload || !rules || asArray(rules).length === 0) {
    return { hidden: false, payload };
  }

  const parts = payload.parts;

  if (!Array.isArray(parts)) {
    if (!payload.domain && !payload.url && reactionNameHidden(payload.name, null, rules)) {
      return { hidden: true, payload: { ...payload, count: 0, account_ids: [] } };
    }

    return { hidden: false, payload };
  }

  const hiddenIds = new Set();
  const kept = [];

  parts.forEach(part => {
    const ids = Array.isArray(part.account_ids) ? part.account_ids.map(String) : [];

    if (partHidden(part, rules)) {
      ids.forEach(id => hiddenIds.add(id));
    } else {
      kept.push({ ...part, account_ids: ids, count: ids.length });
    }
  });

  const accountIds = (payload.account_ids || []).map(String).filter(id => !hiddenIds.has(id));

  if (accountIds.length === 0) {
    return { hidden: true, payload: { ...payload, parts: kept, count: 0, account_ids: [] } };
  }

  return {
    hidden: false,
    payload: { ...payload, parts: kept, count: accountIds.length, account_ids: accountIds },
  };
};

export const reactionTokenStale = (current, incoming) => {
  if (current === null || current === undefined || incoming === null || incoming === undefined || incoming === '') {
    return false;
  }

  const left = String(incoming);
  const right = String(current);

  if (left === right) {
    return false;
  }

  if (left.length === right.length) {
    return left < right;
  }

  return left.length < right.length;
};

export const revisionStale = (current, incoming) => reactionTokenStale(current, incoming);
