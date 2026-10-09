import compareId from '../compare_id';
import { sourceIdentityLabel } from './source';

export const MIX_FETCH_CONCURRENCY = 3;
export const MIX_FETCH_BUDGET = 8;
export const MIX_PAGE_TARGET = 20;

const newer = (left, right) => compareId(left, right) > 0;

const mergeIds = (groups) => {
  const seen = new Set();
  const rows = [];

  groups.forEach(group => {
    group.ids.forEach(id => {
      if (seen.has(id)) {
        return;
      }

      seen.add(id);
      rows.push(id);
    });
  });

  rows.sort((left, right) => compareId(right, left));
  return rows;
};

const membership = (groups) => {
  const map = new Map();

  groups.forEach(group => {
    group.ids.forEach(id => {
      const keys = map.get(id) || [];

      if (keys.indexOf(group.key) === -1) {
        keys.push(group.key);
      }

      map.set(id, keys);
    });
  });

  return map;
};

// A source that still has older pages can only vouch for ids at least as new
// as its oldest fetched id. The safe prefix is the items no incomplete source
// could still insert above.
export const safePrefix = (sources) => {
  const list = sources || [];
  const waiting = list.filter(source => !source.loaded && !source.error);
  const failed = list.filter(source => source.error);
  const usable = list.filter(source => !source.error || source.ids.length);
  const known = mergeIds(usable);

  if (waiting.length) {
    return {
      ids: [],
      membership: membership(usable),
      orderGuaranteed: false,
      waiting: true,
    };
  }

  const incomplete = list.filter(source => !source.error && source.hasMore);
  let limit = null;
  let blocked = false;

  incomplete.forEach(source => {
    if (!source.ids.length) {
      blocked = true;
      return;
    }

    const frontier = source.ids[source.ids.length - 1];

    if (limit === null || newer(frontier, limit)) {
      limit = frontier;
    }
  });

  const ids = blocked ? [] : known.filter(id => limit === null || compareId(id, limit) >= 0);

  return {
    ids,
    membership: membership(usable),
    orderGuaranteed: failed.length === 0 && !blocked,
    waiting: false,
  };
};

export const nextFetchKeys = (sources, { budget = MIX_FETCH_BUDGET, target = MIX_PAGE_TARGET, extend = false, retry = false } = {}) => {
  if (budget <= 0) {
    return [];
  }

  const pending = (sources || []).filter(source => !source.loaded && !source.loading && !source.error);

  if (pending.length) {
    return pending.slice(0, budget).map(source => source.key);
  }

  const emptyOpen = (sources || []).filter(source => source.loaded && source.hasMore && !source.error && !source.loading && !source.ids.length);

  if (emptyOpen.length) {
    return emptyOpen.slice(0, budget).map(source => source.key);
  }

  if (retry) {
    const soft = (sources || []).filter(source => !source.loading && (source.error === 'server' || source.error === 'unavailable'));

    if (soft.length) {
      return soft.slice(0, budget).map(source => source.key);
    }
  }

  const view = safePrefix(sources);

  if (!extend && view.orderGuaranteed && view.ids.length >= target) {
    return [];
  }

  const incomplete = (sources || []).filter(source => source.loaded && source.hasMore && !source.error && !source.loading && source.ids.length);

  if (!incomplete.length) {
    return [];
  }

  if (!extend && view.ids.length >= target) {
    return [];
  }

  let limit = incomplete[0].ids[incomplete[0].ids.length - 1];

  incomplete.forEach(source => {
    const frontier = source.ids[source.ids.length - 1];

    if (newer(frontier, limit)) {
      limit = frontier;
    }
  });

  return incomplete.filter(source => compareId(source.ids[source.ids.length - 1], limit) === 0).slice(0, budget).map(source => source.key);
};

const passesShows = (status, source, me) => {
  const params = source.params || {};
  const shows = params.shows || {};

  if (shows.reblog === false && status.reblog && status.account !== me) {
    return false;
  }

  if (shows.reply === false && status.in_reply_to_id && status.in_reply_to_account_id !== me) {
    return false;
  }

  if (source.type === 'limited' && (status.visibility === 'public' || status.visibility === 'unlisted')) {
    return false;
  }

  if ((source.type === 'home' || source.type === 'limited') && shows[status.visibility] === false) {
    return false;
  }

  return true;
};

const hiddenByFilters = (status, context, filters) => {
  const results = status.filtered || [];

  return results.some(result => {
    const filter = (filters || []).find(item => item.id === result.filter);

    return filter && filter.filter_action === 'hide' && (filter.context || []).indexOf(context) !== -1;
  });
};

export const buildMixView = (sources, statusesById, { me = null, filters = [], contexts = {} } = {}) => {
  const prefix = safePrefix(sources);
  const visible = [];
  const contextById = {};
  const sourceKeysById = {};

  prefix.ids.forEach(id => {
    const status = statusesById[id];
    const keys = prefix.membership.get(id) || [];
    const visibleKeys = keys.filter(key => {
      const source = (sources.find(item => item.key === key) || {}).source;

      if (!source) {
        return false;
      }

      if (!status) {
        return true;
      }

      return passesShows(status, source, me);
    });

    if (!visibleKeys.length) {
      return;
    }

    const available = visibleKeys.map(key => contexts[key]).filter(Boolean);
    const shown = available.find(context => !status || !hiddenByFilters(status, context, filters));

    if (status && available.length && !shown) {
      return;
    }

    visible.push(id);
    sourceKeysById[id] = visibleKeys;
    contextById[id] = shown || available[0] || null;
  });

  const hasMore = (sources || []).some(source => source.hasMore && !source.error);
  const errors = (sources || []).filter(source => source.error).map(source => ({
    key: source.key,
    error: source.error,
    label: source.source ? sourceIdentityLabel(source.source) : source.key,
  }));

  return {
    ids: visible,
    contextById,
    sourceKeysById,
    orderGuaranteed: prefix.orderGuaranteed,
    waiting: prefix.waiting,
    hasMore: hasMore || prefix.waiting,
    errors,
  };
};

export const appendUnique = (existing, incoming) => {
  const seen = new Set(existing);
  const next = existing.slice();

  incoming.forEach(id => {
    if (!seen.has(id)) {
      seen.add(id);
      next.push(id);
    }
  });

  return next;
};
