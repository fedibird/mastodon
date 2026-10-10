import compareId from '../compare_id';
import { sourceIdentityLabel } from './source';

export const MIX_FETCH_CONCURRENCY = 3;
export const MIX_FETCH_BUDGET = 16;
export const MIX_PAGE_SIZE = 40;
export const MIX_PAGE_TARGET = 40;

const newer = (left, right) => compareId(left, right) > 0;

const frontierOf = (source) => {
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

  const incomplete = list.filter(source => !source.error && source.hasMore);
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

  const emptyOpen = (sources || []).filter(source => source.loaded && source.hasMore && !source.error && !source.loading && !source.ids.length);

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

  const incomplete = (sources || []).filter(source => source.loaded && source.hasMore && !source.error && !source.loading && source.ids.length);

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

export const buildMixView = (sources, statusesById, { me = null, filters = [], contexts = {} } = {}) => {
  const prefix = safePrefix(sources);
  const visible = [];
  const contextById = {};
  const sourceKeysById = {};
  const warningsById = {};

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

    const choices = visibleKeys.map(key => ({
      key,
      context: contexts[key],
      results: resultsFor(sources.find(item => item.key === key) || {}, id),
    })).filter(choice => choice.context);
    const shown = choices.find(choice => matchingFilters(choice.results, choice.context, filters, 'hide').length === 0);

    if (choices.length && !shown) {
      return;
    }

    visible.push(id);
    sourceKeysById[id] = visibleKeys;
    contextById[id] = shown ? shown.context : null;
    if (shown) {
      warningsById[id] = matchingFilters(shown.results, shown.context, filters, 'warn').map(filter => filter.title);
    }
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
    warningsById,
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
