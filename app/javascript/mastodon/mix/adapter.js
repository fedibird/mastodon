import { filterContextForSource } from './filter_context';
import { normalizeSource, sourceKey } from './source';

const encodePath = (value) => encodeURIComponent(value);

const visibilityList = (shows, home) => {
  const keys = home ? ['public', 'unlisted', 'private', 'limited', 'direct', 'personal'] : ['private', 'limited', 'direct', 'personal'];

  return keys.filter(key => key === 'public' || key === 'unlisted' || !shows || shows[key] !== false);
};

// Known endpoints only. The descriptor cannot supply a URL.
export const resolveSource = (source) => {
  const normalized = normalizeSource(source);

  if (!normalized.ok) {
    return normalized;
  }

  const value = normalized.source;
  const params = value.params || {};
  let path = null;
  const query = {};

  switch (value.type) {
  case 'home':
    path = '/api/v1/timelines/home';
    query.visibilities = visibilityList(params.shows, true);
    break;
  case 'limited':
    path = '/api/v1/timelines/home';
    query.visibilities = visibilityList(params.shows, false);
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
    filterContext: filterContextForSource(value),
    paging: 'max_id',
  };
};

export const classifyFetchError = (error) => {
  const status = error && error.response && error.response.status;

  if (status === 401 || status === 403) {
    return 'forbidden';
  }

  if (status === 404) {
    return 'not_found';
  }

  if (status >= 500) {
    return 'server';
  }

  return 'unavailable';
};

export const cursorFromNextLink = (next, fallbackId) => {
  if (!next || !next.uri) {
    return fallbackId || null;
  }

  const match = String(next.uri).match(/[?&]max_id=([^&]+)/);

  if (!match) {
    return fallbackId || null;
  }

  try {
    return decodeURIComponent(match[1]);
  } catch (ignored) {
    return fallbackId || null;
  }
};
