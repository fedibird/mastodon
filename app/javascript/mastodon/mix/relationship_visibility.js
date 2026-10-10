const accountIdOf = (account) => {
  if (!account) {
    return null;
  }

  if (typeof account === 'string' || typeof account === 'number') {
    return String(account);
  }

  if (account.get) {
    return account.get('id') ? String(account.get('id')) : null;
  }

  return account.id ? String(account.id) : null;
};

export const relationshipGeneration = (relationships) => {
  if (!relationships || !relationships.get) {
    return 0;
  }

  const count = relationships.get('updateCount');

  return typeof count === 'number' && !Number.isNaN(count) ? count : 0;
};

const PROTECTED_RELATIONSHIP_KEYS = ['blocking', 'muting', 'domain_blocking'];

// A compact page can carry relationships captured before a block or mute.
// Keep those explicit flags, and keep any local fields the page does not repeat.
export const relationshipsAfterGeneration = (relationships, incoming, generation) => {
  if (!incoming || !incoming.length) {
    return [];
  }

  if (relationshipGeneration(relationships) === generation) {
    return incoming;
  }

  return incoming.map(relationship => {
    if (!relationship || relationship.id === undefined || relationship.id === null) {
      return relationship;
    }

    const current = relationships && relationships.get && relationships.get(String(relationship.id));

    if (!current || !current.get) {
      return relationship;
    }

    const merged = { ...relationship };

    PROTECTED_RELATIONSHIP_KEYS.forEach(key => {
      if (current.has(key)) {
        merged[key] = current.get(key);
      }
    });

    current.forEach((value, key) => {
      if (merged[key] !== undefined) {
        return;
      }

      merged[key] = value && value.toJS ? value.toJS() : value;
    });

    return merged;
  });
};

export const relationshipHidesAccount = (relationships, accountId) => {
  if (!relationships || !relationships.get || !accountId) {
    return false;
  }

  const relationship = relationships.get(String(accountId));

  if (!relationship || !relationship.get) {
    return false;
  }

  return relationship.get('blocking') === true || relationship.get('muting') === true;
};

const statusIdOf = (status) => {
  if (!status || status.id === undefined || status.id === null) {
    return null;
  }

  return String(status.id);
};

// Compact pages point reblog at an id. The original lives in referenced_statuses
// or, failing that, in the statuses already stored. An unresolved id is not
// treated as hidden.
const originalStatus = (status, context) => {
  const reblog = status.get ? status.get('reblog') : status.reblog;

  if (!reblog) {
    return null;
  }

  if (typeof reblog === 'object') {
    return reblog;
  }

  const id = String(reblog);
  const indexed = context && context.index && context.index.get(id);

  if (indexed) {
    return indexed;
  }

  const stored = context && context.statuses && context.statuses.get && context.statuses.get(id);

  return stored || null;
};

export const statusIndex = (groups) => {
  const index = new Map();

  (groups || []).forEach(group => {
    (group || []).forEach(status => {
      const id = statusIdOf(status);

      if (id && !index.has(id)) {
        index.set(id, status);
      }
    });
  });

  return index;
};

// A block or mute hides that account's posts and boosts of them. It is not a
// delete tombstone: clearing the relationship lets a later fetch show them.
export const statusHiddenByRelationships = (relationships, status, context) => {
  if (!status) {
    return false;
  }

  const account = status.get ? status.get('account') : status.account;

  if (relationshipHidesAccount(relationships, accountIdOf(account))) {
    return true;
  }

  const original = originalStatus(status, context);

  if (!original) {
    return false;
  }

  const reblogAccount = original.get ? original.get('account') : original.account;

  return relationshipHidesAccount(relationships, accountIdOf(reblogAccount));
};

export const hiddenStatusIds = (relationships, storedStatuses, groups) => {
  const index = statusIndex(groups);
  const hidden = new Set();

  index.forEach(status => {
    if (statusHiddenByRelationships(relationships, status, { index, statuses: storedStatuses })) {
      hidden.add(String(status.id));
    }
  });

  return hidden;
};

export const idHiddenByRelationships = (relationships, statuses, id, pageStatuses, context) => {
  const fromPage = (pageStatuses || []).find(item => item && String(item.id) === String(id));

  if (fromPage) {
    return statusHiddenByRelationships(relationships, fromPage, context || { statuses });
  }

  const stored = statuses && statuses.get && statuses.get(id);

  if (!stored || !stored.get) {
    return false;
  }

  if (statusHiddenByRelationships(relationships, stored)) {
    return true;
  }

  const reblogId = stored.get('reblog');

  if (typeof reblogId !== 'string') {
    return false;
  }

  const original = statuses.get(reblogId);

  return !!(original && relationshipHidesAccount(relationships, accountIdOf(original.get('account'))));
};
