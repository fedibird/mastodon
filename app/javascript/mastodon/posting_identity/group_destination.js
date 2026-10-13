const FEDIBIRD_GROUP_KEY = /^builtin:fedibird-group:([1-9]\d*)$/;
const MITRA_GROUP_KEY = /^protocol:fep-1b12-group:([1-9]\d*)$/;
const NODEBB_GROUP_KEY = /^protocol:fep-1b12-nodebb:([1-9]\d*)$/;

const present = value => value !== null && value !== undefined && value !== '';

const read = (source, key) => {
  if (!source) {
    return undefined;
  }

  if (typeof source.get === 'function') {
    return source.get(key);
  }

  return source[key];
};

const audienceAccountId = source => {
  if (!source) {
    return null;
  }

  if (typeof source.getIn === 'function') {
    return source.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId']) || null;
  }

  const audience = source.activityPubAudience;

  if (!audience) {
    return null;
  }

  if (typeof audience.get === 'function') {
    return audience.get('accountId') || null;
  }

  return audience.accountId || null;
};

// A local Fedibird group is identified by the server context key and the
// same account id on every destination field the composer already has.
// A remote audience is not a local group, even when one of the ids matches.
export function consistentLocalFedibirdGroup (source) {
  if (!source) {
    return false;
  }

  const composer = typeof source.getIn === 'function';
  const contextKey = composer ? source.getIn(['context', 'key']) : read(source, 'contextKey');
  const match = String(contextKey || '').match(FEDIBIRD_GROUP_KEY);

  if (!match || audienceAccountId(source)) {
    return false;
  }

  const ids = [match[1]];
  const push = value => {
    if (present(value)) {
      ids.push(String(value));
    }
  };

  if (composer) {
    push(source.get('posting_context_account_id'));
    push(source.getIn(['context', 'resolvedAccountId']));

    if (source.getIn(['surface', 'kind']) === 'group') {
      push(source.getIn(['surface', 'key']));
    }
  } else {
    push(read(source, 'postingContextAccountId'));
    push(read(source, 'resolvedAccountId'));
    push(read(source, 'groupId'));
  }

  return ids.every(id => id === match[1]);
}

// A supported remote group addresses one account in both the context key
// and the ActivityPub audience. The key shape is not permission to post.
const consistentAudienceGroup = (source, pattern) => {
  if (!source) {
    return false;
  }

  const composer = typeof source.getIn === 'function';
  const contextKey = composer ? source.getIn(['context', 'key']) : read(source, 'contextKey');
  const match = String(contextKey || '').match(pattern);
  const audienceId = audienceAccountId(source);

  if (!match || !audienceId || String(audienceId) !== match[1]) {
    return false;
  }

  const ids = [match[1], String(audienceId)];
  const push = value => {
    if (present(value)) {
      ids.push(String(value));
    }
  };

  if (composer) {
    push(source.get('posting_context_account_id'));
    push(source.getIn(['context', 'resolvedAccountId']));

    if (source.getIn(['surface', 'kind']) === 'group') {
      push(source.getIn(['surface', 'key']));
    }
  } else {
    push(read(source, 'postingContextAccountId'));
    push(read(source, 'resolvedAccountId'));
    push(read(source, 'groupId'));
  }

  return ids.every(id => id === match[1]);
};

// Mitra addresses the group with audience. The key is the Mitra FEP-1b12
// context, and every account id already on the draft has to be that group.
export function consistentMitraGroup (source) {
  return consistentAudienceGroup(source, MITRA_GROUP_KEY);
}

// NodeBB categories use their own context key and the same audience rule.
export function consistentNodebbGroup (source) {
  return consistentAudienceGroup(source, NODEBB_GROUP_KEY);
}

export function consistentSupportedRemoteGroup (source) {
  return consistentMitraGroup(source) || consistentNodebbGroup(source);
}

// A group destination is not only a group column. A posting style can
// address a group from the primary composer without setting surface.kind.
export function composerHasGroupDestination (composer) {
  if (!composer || !composer.get) {
    return false;
  }

  if (composer.getIn(['surface', 'kind']) === 'group') {
    return true;
  }

  if (present(composer.get('posting_context_account_id'))) {
    return true;
  }

  if (present(composer.getIn(['context', 'resolvedAccountId']))) {
    return true;
  }

  return Boolean(composer.getIn(['context', 'protocol', 'activityPub', 'audience']));
}

export function draftHasGroupDestination (draft) {
  const source = draft || {};

  return Boolean(
    source.groupId
    || present(source.postingContextAccountId)
    || present(source.resolvedAccountId)
    || source.activityPubAudience,
  );
}
