import compareId from '../compare_id';
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

export const cursorFromNextUri = (uri) => {
  if (!uri) {
    return { cursor: null };
  }

  if (/^https?:\/\//i.test(uri)) {
    const origin = typeof window !== 'undefined' && window.location ? window.location.origin : '';

    if (!origin || uri.indexOf(origin) !== 0) {
      return { error: 'foreign_link' };
    }
  }

  const match = String(uri).match(/[?&]max_id=([^&#]+)/);

  if (!match) {
    return { error: 'cursor' };
  }

  try {
    return { cursor: decodeURIComponent(match[1]) };
  } catch (ignored) {
    return { error: 'cursor' };
  }
};

export const normalizePage = ({ status, data, nextUri } = {}) => {
  const parsed = pageStatuses(data);

  if (!parsed) {
    return { ok: false, error: 'response' };
  }

  const ids = parsed.statuses.map(item => item && item.id).filter(Boolean);

  if (!descendingIds(ids)) {
    return { ok: false, error: 'order', ids };
  }

  const link = cursorFromNextUri(nextUri);
  const partial = status === 206;

  if (nextUri && link.error) {
    return { ok: false, error: link.error, ids, partial };
  }

  const filterResults = {};

  parsed.statuses.forEach(item => {
    if (!item || !item.id) {
      return;
    }

    filterResults[item.id] = item.filtered || item.filter_results || [];
  });

  const strip = (item) => {
    if (!item) {
      return item;
    }

    const copy = { ...item };

    delete copy.filtered;
    delete copy.filter_results;
    return copy;
  };

  return {
    ok: true,
    partial,
    compact: parsed.compact,
    ids,
    statuses: parsed.statuses.map(strip),
    referencedStatuses: parsed.referencedStatuses.map(strip),
    accounts: parsed.accounts,
    relationships: parsed.relationships,
    filterResults,
    cursor: link.cursor,
    hasMore: !!nextUri,
    frontier: partial || !ids.length ? null : ids[ids.length - 1],
  };
};

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
