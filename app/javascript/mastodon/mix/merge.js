import compareId from '../compare_id';
import { sourceIdentityLabel } from './source';

export const MIX_FETCH_CONCURRENCY = 3;
export const MIX_FETCH_BUDGET = 16;
export const MIX_PAGE_SIZE = 40;
export const MIX_PAGE_TARGET = 40;
export const MIX_RECONCILE_BUDGET = 4;
export const MIX_TOMBSTONE_LIMIT = 200;
// A 206 page can omit rows. One later 200 schedules a single reread from the head.
export const MIX_REREAD_LIMIT = 1;

const newer = (left, right) => compareId(left, right) > 0;

const frontierOf = (source) => {
  if (source.gap) {
    return null;
  }

  if (source.frontier) {
    return source.frontier;
  }

  if (source.partial || !source.ids.length) {
    return null;
  }

  return source.ids[source.ids.length - 1];
};

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

  const incomplete = list.filter(source => !source.error && (source.hasMore || source.gap));
  let limit = null;
  let blocked = false;

  incomplete.forEach(source => {
    const frontier = frontierOf(source);

    if (!frontier) {
      blocked = true;
      return;
    }

    if (limit === null || newer(frontier, limit)) {
      limit = frontier;
    }
  });

  // An unknown frontier, including a 206 page, must not be reported as a
  // finished source. Known ids can still be shown, without an order guarantee.
  const ids = blocked ? known : known.filter(id => limit === null || compareId(id, limit) >= 0);

  return {
    ids,
    membership: membership(usable),
    orderGuaranteed: failed.length === 0 && !blocked,
    waiting: false,
    partial: blocked,
  };
};

export const nextFetchKeys = (sources, { budget = MIX_FETCH_BUDGET, target = MIX_PAGE_TARGET, extend = false, retry = false, now = Date.now() } = {}) => {
  if (budget <= 0) {
    return [];
  }

  const pending = (sources || []).filter(source => !source.loaded && !source.loading && !source.error);

  if (pending.length) {
    return pending.slice(0, budget).map(source => source.key);
  }

  const emptyOpen = (sources || []).filter(source => source.loaded && source.hasMore && !source.error && !source.loading && !source.suspended && !source.ids.length);

  if (emptyOpen.length) {
    return emptyOpen.slice(0, budget).map(source => source.key);
  }

  if (retry) {
    const soft = (sources || []).filter(source => !source.loading && (
      source.error === 'server' || (source.error === 'rate_limit' && (!source.retryAt || source.retryAt <= now))
    ));

    if (soft.length) {
      return soft.slice(0, budget).map(source => source.key);
    }
  }

  const view = safePrefix(sources);

  if (!extend && view.orderGuaranteed && view.ids.length >= target) {
    return [];
  }

  const incomplete = (sources || []).filter(source => source.loaded && source.hasMore && !source.error && !source.loading && !source.suspended && source.ids.length);

  if (!incomplete.length) {
    return [];
  }

  if (!extend && view.ids.length >= target) {
    return [];
  }

  const unknown = incomplete.filter(source => !frontierOf(source));

  if (unknown.length) {
    return unknown.slice(0, budget).map(source => source.key);
  }

  let limit = frontierOf(incomplete[0]);

  incomplete.forEach(source => {
    const frontier = frontierOf(source);

    if (newer(frontier, limit)) {
      limit = frontier;
    }
  });

  return incomplete.filter(source => compareId(frontierOf(source), limit) === 0).slice(0, budget).map(source => source.key);
};

const passesShows = (status, source, me) => {
  const params = source.params || {};
  const shows = params.shows || {};
  const accountId = status.account && status.account.id ? status.account.id : status.account;

  if ((source.type === 'home' || source.type === 'limited') && shows[status.visibility] === false) {
    return false;
  }

  if (source.type === 'limited' && (status.visibility === 'public' || status.visibility === 'unlisted')) {
    return false;
  }

  if (accountId === me) {
    return true;
  }

  if (shows.reblog === false && status.reblog) {
    return false;
  }

  if (shows.reply === false && status.in_reply_to_id && status.in_reply_to_account_id !== me) {
    return false;
  }

  return true;
};

const resultsFor = (source, id) => {
  const stored = source.filterResults && source.filterResults[id];

  return stored || [];
};

const matchingFilters = (results, context, filters, action) => (results || []).map(result => {
  return (filters || []).find(item => item.id === result.filter && item.filter_action === action && (item.context || []).indexOf(context) !== -1);
}).filter(Boolean);

const rememberSource = (sourceKeysById, id, key) => {
  const keys = sourceKeysById[id] || [];

  if (keys.indexOf(key) === -1) {
    keys.push(key);
  }

  sourceKeysById[id] = keys;
};

const warnTitles = (results, context, filters) => (
  context ? matchingFilters(results, context, filters, 'warn').map(filter => filter.title) : []
);

const hidesSource = (results, context, filters) => (
  !!(context && matchingFilters(results, context, filters, 'hide').length)
);

const rememberWarning = (sourceWarningsById, id, key, titles) => {
  if (!sourceWarningsById[id]) {
    sourceWarningsById[id] = {};
  }

  sourceWarningsById[id][key] = titles;
};

const considerId = (id, key, source, results, statusesById, options, visible, contextById, sourceKeysById, warningsById, sourceWarningsById) => {
  const { me, filters, contexts, tombstones } = options;

  if (tombstones && tombstones.indexOf(id) !== -1) {
    return;
  }

  if (!source) {
    return;
  }

  const status = statusesById[id];

  if (status && !passesShows(status, source, me)) {
    return;
  }

  const context = contexts[key];
  const choiceResults = results || [];

  if (hidesSource(choiceResults, context, filters)) {
    return;
  }

  rememberSource(sourceKeysById, id, key);
  rememberWarning(sourceWarningsById, id, key, warnTitles(choiceResults, context, filters));

  if (visible.indexOf(id) === -1) {
    visible.push(id);
    contextById[id] = context || null;
    warningsById[id] = warnTitles(choiceResults, context, filters);
  }
};

export const buildMixView = (sources, statusesById, { me = null, filters = [], contexts = {}, live = [], tombstones = [], pending = [] } = {}) => {
  const prefix = safePrefix(sources);
  const visible = [];
  const contextById = {};
  const sourceKeysById = {};
  const sourceWarningsById = {};
  const warningsById = {};
  const options = { me, filters, contexts, tombstones };
  const held = new Set(pending || []);

  prefix.ids.forEach(id => {
    if (tombstones && tombstones.indexOf(id) !== -1) {
      return;
    }

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

    const choices = visibleKeys.map(key => ({
      key,
      context: contexts[key],
      results: resultsFor(sources.find(item => item.key === key) || {}, id),
    })).filter(choice => choice.context);
    const shown = choices.find(choice => !hidesSource(choice.results, choice.context, filters));

    if (choices.length && !shown) {
      return;
    }

    const displayKeys = visibleKeys.filter(key => {
      const choice = choices.find(item => item.key === key);

      return !choice || !hidesSource(choice.results, choice.context, filters);
    });

    if (!displayKeys.length) {
      return;
    }

    visible.push(id);
    sourceKeysById[id] = displayKeys;
    sourceWarningsById[id] = {};
    displayKeys.forEach(key => {
      const choice = choices.find(item => item.key === key);

      sourceWarningsById[id][key] = choice ? warnTitles(choice.results, choice.context, filters) : [];
    });
    contextById[id] = shown ? shown.context : null;
    if (shown) {
      warningsById[id] = warnTitles(shown.results, shown.context, filters);
    }
  });

  (live || []).forEach(source => {
    (source.ids || []).forEach(id => {
      if (held.has(id)) {
        return;
      }

      const record = sources.find(item => item.key === source.key) || source;

      considerId(id, source.key, record.source || source.source, (source.filterResults && source.filterResults[id]) || [], statusesById, options, visible, contextById, sourceKeysById, warningsById, sourceWarningsById);
    });
  });

  visible.sort((left, right) => compareId(right, left));

  const hasMore = (sources || []).some(source => source.hasMore && !source.error && !source.suspended);
  const suspended = (sources || []).filter(source => source.suspended).map(source => ({
    key: source.key,
    label: source.source ? sourceIdentityLabel(source.source) : source.key,
  }));
  const errors = (sources || []).filter(source => source.error).map(source => ({
    key: source.key,
    error: source.error,
    retryAt: source.retryAt || null,
    label: source.source ? sourceIdentityLabel(source.source) : source.key,
  }));

  return {
    ids: visible,
    contextById,
    sourceKeysById,
    sourceWarningsById,
    warningsById,
    orderGuaranteed: prefix.orderGuaranteed,
    waiting: prefix.waiting,
    hasMore: hasMore || prefix.waiting,
    suspended,
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
