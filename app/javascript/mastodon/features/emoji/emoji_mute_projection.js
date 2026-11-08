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

export const unicodeMatches = (stored, reactionName) => (
  typeof stored === 'string' && typeof reactionName === 'string' && stored === reactionName
);

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

const hideKey = rule => {
  if (read(read(rule, 'effects'), 'hide_reactions') !== true) {
    return null;
  }

  const emoji = read(rule, 'emoji') || {};

  if (read(emoji, 'kind') === 'unicode') {
    return `u:${read(emoji, 'native')}`;
  }

  if (read(emoji, 'scope') === 'local') {
    return `l:${read(emoji, 'custom_emoji_id')}`;
  }

  return `r:${read(emoji, 'domain')}:${read(emoji, 'shortcode')}`;
};

// Identities with hide_reactions, in a stable order. Used to see whether a
// newly applied document can still be projected from the reactions on screen.
export const hideReactionSignature = rules => asArray(rules).map(hideKey).filter(key => key !== null).sort().join('\n');

export const hideSignatureShrunk = (previous, next) => {
  const after = new Set(String(next || '').split('\n').filter(Boolean));

  return String(previous || '').split('\n').filter(Boolean).some(key => !after.has(key));
};

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
  const next = { ...payload, parts: kept, count: accountIds.length, account_ids: accountIds };
  const previousRepresentative = representativeId(parts);
  const keptRepresentative = representativeId(kept);

  if (previousRepresentative && previousRepresentative !== keptRepresentative) {
    Object.assign(next, displayFromParts(kept));
  }

  if (accountIds.length === 0) {
    return { hidden: true, payload: next };
  }

  return { hidden: false, payload: next };
};

const partEmojiId = part => {
  const id = read(part, 'custom_emoji_id') || read(identityOf(part), 'custom_emoji_id');
  return id === undefined || id === null || id === '' ? null : String(id);
};

const representativeId = parts => {
  const ids = parts.map(partEmojiId).filter(id => id !== null);
  if (ids.length === 0) {
    return null;
  }

  return ids.slice().sort((left, right) => {
    if (left.length === right.length) {
      return left < right ? -1 : 1;
    }

    return left.length < right.length ? -1 : 1;
  })[0];
};

const displayFromParts = parts => {
  const chosen = parts.find(part => partEmojiId(part) === representativeId(parts));
  if (!chosen) {
    return { url: null, static_url: null, domain: null, width: null, height: null, alternate_name: null, ruby: null };
  }

  return {
    url: read(chosen, 'url') ?? null,
    static_url: read(chosen, 'static_url') ?? null,
    domain: read(chosen, 'domain') ?? null,
    width: read(chosen, 'width') ?? null,
    height: read(chosen, 'height') ?? null,
    alternate_name: read(chosen, 'alternate_name') ?? null,
    ruby: read(chosen, 'ruby') ?? null,
  };
};

const projectable = (group, rules) => {
  if (!rules || asArray(rules).length === 0) {
    return true;
  }

  if (Array.isArray(group.parts)) {
    return true;
  }

  return !group.domain && !group.url && !group.static_url;
};

export const projectStatusReactions = (groups, rules) => {
  if (!Array.isArray(groups) || groups.some(group => !projectable(group, rules))) {
    return null;
  }

  return groups
    .map(group => projectStreamReaction(group, rules))
    .filter(result => !result.hidden && result.payload.count > 0)
    .map(result => result.payload);
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

const keepPreviousReactions = (previous, status) => {
  if (!previous || typeof previous.get !== 'function') {
    const next = { ...status };
    delete next.emoji_reactions;
    delete next.emoji_reactions_count;
    delete next.emoji_mutes_revision;
    return next;
  }

  const reactions = previous.get('emoji_reactions');

  return {
    ...status,
    emoji_reactions: reactions && typeof reactions.toJS === 'function' ? reactions.toJS() : status.emoji_reactions,
    emoji_reactions_count: previous.get('emoji_reactions_count'),
    emoji_reactions_cache_token: previous.get('emoji_reactions_cache_token'),
    emoji_mutes_revision: previous.get('emoji_mutes_revision'),
  };
};

// Anonymous status updates have no viewer revision. Project them with the
// rules already fetched. Until that fetch has caught up, keep the reactions
// already on screen and still import the edited text.
const withRevision = (status, revision) => {
  if (revision === null || revision === undefined) {
    return status;
  }

  const current = status.emoji_mutes_revision;

  // Keep a revision that is already the same or newer. `revisionStale(stamp,
  // current)` is true only when the copy we would write is older.
  if (current !== null && current !== undefined && !revisionStale(revision, current)) {
    return status;
  }

  return { ...status, emoji_mutes_revision: revision };
};

// A payload is safe to show when the fetched mute document has caught up
// with every observed change and the payload revision is at least that
// document. Equality with the applied revision is not enough while a newer
// change is still being fetched. An older revision must not bring reactions
// back or lower the revision stored on the status.
export const guardImportedReactions = (previous, status, rules, reactionsAccepted, appliedRevision, observedRevision) => {
  if (!status || typeof status !== 'object') {
    return status;
  }

  const incoming = status.emoji_mutes_revision;
  const current = previous && typeof previous.get === 'function' ? previous.get('emoji_mutes_revision') : null;
  const waitingForDocument = observedRevision !== null && observedRevision !== undefined && (
    appliedRevision === null || appliedRevision === undefined || revisionStale(observedRevision, appliedRevision)
  );

  if (incoming !== null && incoming !== undefined && current !== null && current !== undefined && revisionStale(current, incoming)) {
    return keepPreviousReactions(previous, status);
  }

  if (waitingForDocument) {
    return keepPreviousReactions(previous, status);
  }

  const globallyStale = incoming !== null && incoming !== undefined && appliedRevision !== null && appliedRevision !== undefined && revisionStale(appliedRevision, incoming);

  if (!globallyStale && incoming !== null && incoming !== undefined) {
    return status;
  }

  if (!reactionsAccepted) {
    return keepPreviousReactions(previous, status);
  }

  const projected = projectStatusReactions(status.emoji_reactions, rules);

  if (!projected) {
    return withRevision(keepPreviousReactions(previous, status), globallyStale ? appliedRevision : null);
  }

  const keptRevision = globallyStale || current === null || current === undefined ? appliedRevision : current;

  return withRevision({
    ...status,
    emoji_reactions: projected,
    emoji_reactions_count: projected.reduce((sum, group) => sum + Number(group.count || 0), 0),
  }, keptRevision);
};
