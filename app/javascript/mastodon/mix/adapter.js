import compareId from '../compare_id';
import { normalizeFilterResult } from '../actions/importer/normalizer';
import { enableLimitedTimeline, hideDirectFromTimeline, hidePersonalFromTimeline } from '../initial_state';
import { filterContextForSource } from './filter_context';
import { normalizeSource, sourceKey } from './source';

const encodePath = (value) => encodeURIComponent(value);

export const visibilityConstraints = (overrides = {}) => ({
  enableLimitedTimeline: Object.prototype.hasOwnProperty.call(overrides, 'enableLimitedTimeline') ? overrides.enableLimitedTimeline === true : enableLimitedTimeline === true,
  hideDirectFromTimeline: Object.prototype.hasOwnProperty.call(overrides, 'hideDirectFromTimeline') ? overrides.hideDirectFromTimeline === true : hideDirectFromTimeline === true,
  hidePersonalFromTimeline: Object.prototype.hasOwnProperty.call(overrides, 'hidePersonalFromTimeline') ? overrides.hidePersonalFromTimeline === true : hidePersonalFromTimeline === true,
});

const allowedByInstance = (key, constraints) => {
  if (key === 'direct' && constraints.hideDirectFromTimeline) {
    return false;
  }

  if (key === 'personal' && constraints.hidePersonalFromTimeline) {
    return false;
  }

  return true;
};

const visibilityList = (shows, home, constraints) => {
  const keys = home ? ['public', 'unlisted', 'private', 'limited', 'direct', 'personal'] : ['private', 'limited', 'direct', 'personal'];

  return keys.filter(key => {
    if ((key === 'public' || key === 'unlisted') && home) {
      return true;
    }

    if (shows && shows[key] === false) {
      return false;
    }

    return allowedByInstance(key, constraints);
  });
};

// Known endpoints only. The descriptor cannot supply a URL.
export const resolveRequest = (source, cursor, constraintOverrides) => {
  const normalized = normalizeSource(source);

  if (!normalized.ok) {
    return normalized;
  }

  const constraints = visibilityConstraints(constraintOverrides || {});
  const value = normalized.source;
  const params = value.params || {};
  let path = null;
  const query = { compact: true };

  if (cursor) {
    query.max_id = cursor;
  }

  switch (value.type) {
  case 'home':
    path = '/api/v1/timelines/home';
    query.visibilities = visibilityList(params.shows, true, constraints);
    break;
  case 'limited':
    if (!constraints.enableLimitedTimeline) {
      return { ok: false, error: 'unavailable', key: sourceKey(value), source: value };
    }

    path = '/api/v1/timelines/home';
    query.visibilities = visibilityList(params.shows, false, constraints);
    break;
  case 'personal':
    path = '/api/v1/timelines/personal';
    if (params.onlyMedia) {
      query.only_media = true;
    }
    if (params.withoutMedia) {
      query.without_media = true;
    }
    break;
  case 'public':
    path = '/api/v1/timelines/public';
    break;
  case 'remote':
    path = '/api/v1/timelines/public';
    query.remote = true;
    break;
  case 'domain':
    path = '/api/v1/timelines/public';
    query.local = false;
    query.domain = value.domain;
    break;
  case 'hashtag':
    path = `/api/v1/timelines/tag/${encodePath(value.id)}`;
    if (params.any) {
      query.any = params.any;
    }
    if (params.all) {
      query.all = params.all;
    }
    if (params.none) {
      query.none = params.none;
    }
    break;
  case 'list':
    path = `/api/v1/timelines/list/${encodePath(value.id)}`;
    break;
  case 'group':
    path = `/api/v1/timelines/group/${encodePath(value.id)}`;
    if (params.tagged) {
      query.tagged = params.tagged;
    }
    break;
  case 'account':
    path = `/api/v1/accounts/${encodePath(value.id)}/statuses`;
    query.exclude_replies = !params.withReplies;
    query.exclude_reblogs = !!params.withoutReblogs;
    if (params.tagged) {
      query.tagged = params.tagged;
    }
    break;
  default:
    return { ok: false, error: 'type_unknown' };
  }

  if (params.onlyMedia && value.type !== 'personal') {
    query.only_media = true;
  }

  if (params.withoutMedia && value.type !== 'personal') {
    query.without_media = true;
  }

  if (params.withoutBot) {
    query.without_bot = true;
  }

  return {
    ok: true,
    key: sourceKey(value),
    source: value,
    path,
    params: query,
    filterContext: filterContext(value),
    paging: 'max_id',
  };
};

export const resolveSource = (source) => resolveRequest(source);

export const filterContext = (source) => filterContextForSource(source);

const pageStatuses = (data) => {
  if (Array.isArray(data)) {
    return {
      compact: false,
      statuses: data,
      referencedStatuses: [],
      accounts: [],
      relationships: [],
    };
  }

  if (data && Array.isArray(data.statuses)) {
    return {
      compact: true,
      statuses: data.statuses,
      referencedStatuses: data.referenced_statuses || [],
      accounts: data.accounts || [],
      relationships: data.relationships || [],
    };
  }

  return null;
};

const descendingIds = (ids) => {
  for (let i = 1; i < ids.length; i += 1) {
    if (compareId(ids[i - 1], ids[i]) <= 0) {
      return false;
    }
  }

  return true;
};

const pageOrigin = (origin) => {
  if (origin) {
    return origin;
  }

  if (typeof window !== 'undefined' && window.location && window.location.origin) {
    return window.location.origin;
  }

  return '';
};

// Same-origin is the URL origin, not a string prefix. The link is never fetched.
export const cursorFromNextUri = (uri, { path, origin } = {}) => {
  if (!uri) {
    return { cursor: null };
  }

  const base = pageOrigin(origin);
  let url;

  try {
    url = new URL(uri, base ? `${base}/` : undefined);
  } catch (ignored) {
    return { error: 'cursor' };
  }

  if (!base || url.origin !== base) {
    return { error: 'foreign_link' };
  }

  if (path && url.pathname !== path) {
    return { error: 'endpoint' };
  }

  const maxId = url.searchParams.get('max_id');

  if (!maxId || !/^[0-9]+$/.test(maxId)) {
    return { error: 'cursor' };
  }

  return { cursor: maxId };
};

const storedFilterResults = (item) => {
  const results = item.filtered || item.filter_results || [];

  return results.map(normalizeFilterResult).filter(result => result && result.filter);
};

const filterDefinitions = (items) => {
  const filters = [];
  const seen = new Set();

  items.forEach(item => {
    (item.filtered || item.filter_results || []).forEach(result => {
      if (!result || !result.filter || typeof result.filter !== 'object' || !result.filter.id) {
        return;
      }

      const id = String(result.filter.id);

      if (seen.has(id)) {
        return;
      }

      seen.add(id);
      filters.push({ ...result.filter, id });
    });
  });

  return filters;
};

export const normalizePage = ({ status, data, nextUri, path, origin } = {}) => {
  const parsed = pageStatuses(data);

  if (!parsed) {
    return { ok: false, error: 'response' };
  }

  const ids = parsed.statuses.map(item => item && item.id).filter(Boolean);

  if (!descendingIds(ids)) {
    return { ok: false, error: 'order', ids };
  }

  const link = cursorFromNextUri(nextUri, { path, origin });
  const partial = status === 206;

  if (nextUri && link.error) {
    return { ok: false, error: link.error, ids, partial };
  }

  const filterResults = {};

  parsed.statuses.forEach(item => {
    if (!item || !item.id) {
      return;
    }

    filterResults[item.id] = storedFilterResults(item);
  });

  // 206 means the feed was still being rebuilt, so this page can omit rows.
  // It is not a confirmed frontier. Without a next cursor the same request
  // must not be repeated automatically. A later 200 does not close the gap.
  const hasMore = partial || !!nextUri;

  return {
    ok: true,
    partial,
    suspended: partial && !link.cursor,
    compact: parsed.compact,
    ids,
    statuses: parsed.statuses,
    referencedStatuses: parsed.referencedStatuses,
    accounts: parsed.accounts,
    relationships: parsed.relationships,
    filters: filterDefinitions(parsed.statuses),
    filterResults,
    cursor: link.cursor,
    hasMore,
    frontier: partial || !ids.length ? null : ids[ids.length - 1],
  };
};

const nestedStatusIds = (status, ids) => {
  if (!status || !status.id || ids.indexOf(status.id) !== -1) {
    return;
  }

  ids.push(status.id);

  if (status.reblog) {
    nestedStatusIds(status.reblog, ids);
  }

  if (status.quote) {
    nestedStatusIds(status.quote, ids);
  }
};

export const previousStatusesForImport = (statuses, bodies) => {
  const ids = [];

  (bodies || []).forEach(status => nestedStatusIds(status, ids));

  const previous = {};

  ids.forEach(id => {
    const status = statuses && statuses.get ? statuses.get(id) : null;

    if (status && status.toJS) {
      previous[id] = status.toJS();
    }
  });

  return previous;
};

// Mix pages must not erase filtered results already stored for a status.
export const statusesForSharedImport = (statuses, previousById = {}) => (statuses || []).map(status => {
  if (!status || !status.id) {
    return status;
  }

  const copy = { ...status };

  delete copy.filtered;
  delete copy.filter_results;

  const previous = previousById[status.id];

  if (previous && previous.filtered) {
    copy.filtered = previous.filtered;
  }

  if (copy.reblog && copy.reblog.id) {
    copy.reblog = statusesForSharedImport([copy.reblog], previousById)[0];
  }

  if (copy.quote && copy.quote.id) {
    copy.quote = statusesForSharedImport([copy.quote], previousById)[0];
  }

  return copy;
});

export const classifyFetchFailure = (error) => {
  const status = error && error.response && error.response.status;
  const headers = error && error.response && error.response.headers;

  if (status === 401 || status === 403) {
    return { kind: 'forbidden' };
  }

  if (status === 404) {
    return { kind: 'not_found' };
  }

  if (status === 429) {
    const header = headers && (headers['retry-after'] || headers['Retry-After']);
    const seconds = parseInt(header, 10);

    return {
      kind: 'rate_limit',
      retryAt: Date.now() + ((Number.isFinite(seconds) ? seconds : 60) * 1000),
    };
  }

  if (status >= 500) {
    return { kind: 'server' };
  }

  return { kind: 'unavailable' };
};

export const classifyFetchError = (error) => classifyFetchFailure(error).kind;
