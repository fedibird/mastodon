import { fetchRelationshipsSuccess, fetchRelationshipsFromStatuses } from './accounts';
import api, { getLinks } from '../api';
import { importFetchedStatuses, importFetchedAccounts } from './importer';

export const EMOJI_REACTIONED_STATUSES_FETCH_REQUEST = 'EMOJI_REACTIONED_STATUSES_FETCH_REQUEST';
export const EMOJI_REACTIONED_STATUSES_FETCH_SUCCESS = 'EMOJI_REACTIONED_STATUSES_FETCH_SUCCESS';
export const EMOJI_REACTIONED_STATUSES_FETCH_FAIL    = 'EMOJI_REACTIONED_STATUSES_FETCH_FAIL';

export const EMOJI_REACTIONED_STATUSES_EXPAND_REQUEST = 'EMOJI_REACTIONED_STATUSES_EXPAND_REQUEST';
export const EMOJI_REACTIONED_STATUSES_EXPAND_SUCCESS = 'EMOJI_REACTIONED_STATUSES_EXPAND_SUCCESS';
export const EMOJI_REACTIONED_STATUSES_EXPAND_FAIL    = 'EMOJI_REACTIONED_STATUSES_EXPAND_FAIL';

export const EMOJI_REACTION_EMOJIS_FETCH_REQUEST = 'EMOJI_REACTION_EMOJIS_FETCH_REQUEST';
export const EMOJI_REACTION_EMOJIS_FETCH_SUCCESS = 'EMOJI_REACTION_EMOJIS_FETCH_SUCCESS';
export const EMOJI_REACTION_EMOJIS_FETCH_FAIL    = 'EMOJI_REACTION_EMOJIS_FETCH_FAIL';

export const DEFAULT_EMOJI_REACTIONED_STATUSES_LIST_KEY = 'default';

export function emojiReactionedStatusesListKey(columnId) {
  return columnId || DEFAULT_EMOJI_REACTIONED_STATUSES_LIST_KEY;
}

export function emojiReactionFilterValues(emojis) {
  if (!emojis) {
    return [];
  }

  if (typeof emojis.toArray === 'function') {
    return emojis.toArray();
  }

  return Array.from(emojis);
}

export function getEmojiReactionQueryKey({ emojis = [], onlyMedia = false, withoutMedia = false } = {}) {
  return JSON.stringify({
    emojis: Array.from(new Set(emojiReactionFilterValues(emojis))).sort(),
    onlyMedia: !!onlyMedia,
    withoutMedia: !!withoutMedia,
  });
}

export function pinnedEmojiReactionColumnParams({ emojis, onlyMedia, withoutMedia } = {}) {
  return {
    emojis: emojiReactionFilterValues(emojis),
    other: {
      onlyMedia: !!onlyMedia,
      withoutMedia: !!withoutMedia,
    },
  };
}

function emojiReactionRequestParams(emojis, onlyMedia, withoutMedia) {
  const params = { compact: true };

  if (emojis.length) {
    params.emojis = emojis;
  }

  if (onlyMedia) {
    params.only_media = true;
  }

  if (withoutMedia) {
    params.without_media = true;
  }

  return params;
}

function importEmojiReactionedStatuses(dispatch, data) {
  if (data && typeof data === 'object' && 'statuses' in data && 'accounts' in data) {
    const { statuses, referenced_statuses, accounts, relationships } = data;
    dispatch(importFetchedAccounts(accounts));
    dispatch(importFetchedStatuses(statuses.concat(referenced_statuses || [])));
    dispatch(fetchRelationshipsSuccess(relationships));
    return statuses;
  }

  const statuses = Array.isArray(data) ? data : [];
  dispatch(importFetchedStatuses(statuses));
  dispatch(fetchRelationshipsFromStatuses(statuses));
  return statuses;
}

export function fetchEmojiReactionedStatuses({
  listKey = DEFAULT_EMOJI_REACTIONED_STATUSES_LIST_KEY,
  emojis = [],
  onlyMedia = false,
  withoutMedia = false,
} = {}) {
  return (dispatch, getState) => {
    const emojiValues = emojiReactionFilterValues(emojis);
    const queryKey = getEmojiReactionQueryKey({ emojis: emojiValues, onlyMedia, withoutMedia });
    const current = getState().getIn(['emoji_reactioned_statuses', 'lists', listKey]);

    if (current && current.get('isLoading') && current.get('queryKey') === queryKey) {
      return Promise.resolve();
    }

    const filters = {
      emojis: emojiValues,
      onlyMedia: !!onlyMedia,
      withoutMedia: !!withoutMedia,
    };

    dispatch(fetchEmojiReactionedStatusesRequest(listKey, queryKey, filters));

    return api(getState).get('/api/v1/emoji_reactions', {
      params: emojiReactionRequestParams(emojiValues, filters.onlyMedia, filters.withoutMedia),
    }).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      const statuses = importEmojiReactionedStatuses(dispatch, response.data);
      dispatch(fetchEmojiReactionedStatusesSuccess(listKey, queryKey, statuses, next ? next.uri : null));
    }).catch(error => {
      dispatch(fetchEmojiReactionedStatusesFail(listKey, queryKey, error));
    });
  };
}

export function fetchEmojiReactionedStatusesRequest(listKey, queryKey, filters) {
  return {
    type: EMOJI_REACTIONED_STATUSES_FETCH_REQUEST,
    listKey,
    queryKey,
    filters,
  };
}

export function fetchEmojiReactionedStatusesSuccess(listKey, queryKey, statuses, next) {
  return {
    type: EMOJI_REACTIONED_STATUSES_FETCH_SUCCESS,
    listKey,
    queryKey,
    statuses,
    next,
  };
}

export function fetchEmojiReactionedStatusesFail(listKey, queryKey, error) {
  return {
    type: EMOJI_REACTIONED_STATUSES_FETCH_FAIL,
    listKey,
    queryKey,
    error,
  };
}

export function expandEmojiReactionedStatuses(listKey = DEFAULT_EMOJI_REACTIONED_STATUSES_LIST_KEY) {
  return (dispatch, getState) => {
    const list = getState().getIn(['emoji_reactioned_statuses', 'lists', listKey]);
    const url = list ? list.get('next') : null;
    const queryKey = list ? list.get('queryKey') : null;

    if (!list || url === null || (list.get('isLoading') && list.get('queryKey') === queryKey)) {
      return Promise.resolve();
    }

    dispatch(expandEmojiReactionedStatusesRequest(listKey, queryKey));

    return api(getState).get(url).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      const statuses = importEmojiReactionedStatuses(dispatch, response.data);
      dispatch(expandEmojiReactionedStatusesSuccess(listKey, queryKey, statuses, next ? next.uri : null));
    }).catch(error => {
      dispatch(expandEmojiReactionedStatusesFail(listKey, queryKey, error));
    });
  };
}

export function expandEmojiReactionedStatusesRequest(listKey, queryKey) {
  return {
    type: EMOJI_REACTIONED_STATUSES_EXPAND_REQUEST,
    listKey,
    queryKey,
  };
}

export function expandEmojiReactionedStatusesSuccess(listKey, queryKey, statuses, next) {
  return {
    type: EMOJI_REACTIONED_STATUSES_EXPAND_SUCCESS,
    listKey,
    queryKey,
    statuses,
    next,
  };
}

export function expandEmojiReactionedStatusesFail(listKey, queryKey, error) {
  return {
    type: EMOJI_REACTIONED_STATUSES_EXPAND_FAIL,
    listKey,
    queryKey,
    error,
  };
}

export function fetchEmojiReactionEmojiCatalog({ force = false } = {}) {
  return (dispatch, getState) => {
    const catalog = getState().getIn(['emoji_reactioned_statuses', 'catalog']);

    if (catalog && catalog.get('isLoading')) {
      return Promise.resolve();
    }

    if (catalog && catalog.get('loaded') && !catalog.get('stale') && !force) {
      return Promise.resolve();
    }

    dispatch(fetchEmojiReactionEmojiCatalogRequest());

    return api(getState).get('/api/v1/emoji_reactions/emojis').then(response => {
      dispatch(fetchEmojiReactionEmojiCatalogSuccess(response.data || []));
    }).catch(error => {
      dispatch(fetchEmojiReactionEmojiCatalogFail(error));
    });
  };
}

export function fetchEmojiReactionEmojiCatalogRequest() {
  return {
    type: EMOJI_REACTION_EMOJIS_FETCH_REQUEST,
  };
}

export function fetchEmojiReactionEmojiCatalogSuccess(emojis) {
  return {
    type: EMOJI_REACTION_EMOJIS_FETCH_SUCCESS,
    emojis,
  };
}

export function fetchEmojiReactionEmojiCatalogFail(error) {
  return {
    type: EMOJI_REACTION_EMOJIS_FETCH_FAIL,
    error,
  };
}
