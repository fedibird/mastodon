import { HISTORY_CAPABILITY } from './constants';

const tagValues = (tags, mode) => {
  const list = tags && tags[mode];

  if (!list || !list.length) {
    return [];
  }

  return list.map(tag => tag.value).filter(value => typeof value === 'string' && value.length > 0);
};

// These match the params expandTimeline already sends. False booleans are
// kept on purpose: omitting without_bot lets the server apply a user default.
// Link headers are not a substitute. Home omits visibilities, tag omits
// any/all/none, and the personal prev/next URLs point at the home timeline.

export const homeHistoryContract = (visibilities) => ({
  source: 'home',
  capability: HISTORY_CAPABILITY.REDIS,
  path: '/api/v1/timelines/home',
  params: { visibilities },
});

export const limitedHistoryContract = (visibilities) => ({
  source: 'limited',
  capability: HISTORY_CAPABILITY.REDIS,
  path: '/api/v1/timelines/home',
  params: { visibilities },
});

export const listHistoryContract = (id) => ({
  source: 'list',
  capability: HISTORY_CAPABILITY.REDIS,
  path: `/api/v1/timelines/list/${id}`,
  params: {},
});

export const hashtagHistoryContract = (hashtag, tags) => ({
  source: 'hashtag',
  capability: HISTORY_CAPABILITY.DATABASE,
  path: `/api/v1/timelines/tag/${hashtag}`,
  params: {
    any: tagValues(tags, 'any'),
    all: tagValues(tags, 'all'),
    none: tagValues(tags, 'none'),
  },
});

export const publicHistoryContract = ({ onlyRemote, onlyMedia, withoutMedia, withoutBot } = {}) => ({
  source: 'public',
  capability: HISTORY_CAPABILITY.DATABASE,
  path: '/api/v1/timelines/public',
  params: {
    remote: !!onlyRemote,
    only_media: !!onlyMedia,
    without_media: !!withoutMedia,
    without_bot: !!withoutBot,
  },
});

export const domainHistoryContract = (domain, { onlyMedia, withoutMedia, withoutBot } = {}) => ({
  source: 'domain',
  capability: HISTORY_CAPABILITY.DATABASE,
  path: '/api/v1/timelines/public',
  params: {
    local: false,
    domain,
    only_media: !!onlyMedia,
    without_media: !!withoutMedia,
    without_bot: !!withoutBot,
  },
});

export const groupHistoryContract = (id, { onlyMedia, withoutMedia, tagged } = {}) => ({
  source: 'group',
  capability: HISTORY_CAPABILITY.DATABASE,
  path: `/api/v1/timelines/group/${id}`,
  params: {
    only_media: !!onlyMedia,
    without_media: !!withoutMedia,
    tagged,
  },
});

export const personalHistoryContract = ({ onlyMedia, withoutMedia } = {}) => ({
  source: 'personal',
  capability: HISTORY_CAPABILITY.DATABASE,
  path: '/api/v1/timelines/personal',
  params: {
    only_media: !!onlyMedia,
    without_media: !!withoutMedia,
  },
});

export const historyRequestParams = (contract, direction, cursor, limit) => {
  const params = {
    ...(contract && contract.params ? contract.params : {}),
    limit,
    compact: true,
  };

  delete params.max_id;
  delete params.min_id;
  delete params.since_id;

  if (direction === 'newer') {
    params.min_id = cursor;
  } else {
    params.max_id = cursor;
  }

  return params;
};
