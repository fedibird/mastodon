import { fetchRelationshipsSuccess, fetchRelationshipsFromStatuses } from './accounts';
import api, { getLinks } from '../api';
import { importFetchedStatuses, importFetchedAccounts } from './importer';

export const BOOKMARKED_STATUSES_FETCH_REQUEST = 'BOOKMARKED_STATUSES_FETCH_REQUEST';
export const BOOKMARKED_STATUSES_FETCH_SUCCESS = 'BOOKMARKED_STATUSES_FETCH_SUCCESS';
export const BOOKMARKED_STATUSES_FETCH_FAIL = 'BOOKMARKED_STATUSES_FETCH_FAIL';

export const BOOKMARKED_STATUSES_EXPAND_REQUEST = 'BOOKMARKED_STATUSES_EXPAND_REQUEST';
export const BOOKMARKED_STATUSES_EXPAND_SUCCESS = 'BOOKMARKED_STATUSES_EXPAND_SUCCESS';
export const BOOKMARKED_STATUSES_EXPAND_FAIL = 'BOOKMARKED_STATUSES_EXPAND_FAIL';

const DEFAULT_LIST_KEY = 'bookmarks';

// Each pinned column owns its query/cursor. Standalone modes also have separate
// cursors, so switching order cannot reuse an incompatible page.
export const bookmarksListKey = (columnId, sortByPostDate = false) => (
  columnId ? `bookmarks:${columnId}` : (sortByPostDate ? 'bookmarks:status' : DEFAULT_LIST_KEY)
);

export const bookmarksQueryKey = ({ onlyMedia = false, withoutMedia = false, sortByPostDate = false } = {}) => JSON.stringify({
  onlyMedia: !!onlyMedia,
  withoutMedia: !!withoutMedia,
  sortByPostDate: !!sortByPostDate,
});

const requestParams = ({ onlyMedia, withoutMedia, sortByPostDate }) => [
  'compact=true',
  onlyMedia ? 'only_media=true' : null,
  withoutMedia ? 'without_media=true' : null,
  sortByPostDate ? 'order=status' : null,
].filter(Boolean).join('&');

function importStatuses(dispatch, data) {
  if (data && 'statuses' in data && 'accounts' in data) {
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

export function fetchBookmarkedStatuses({ listKey = DEFAULT_LIST_KEY, onlyMedia = false, withoutMedia = false, sortByPostDate = false } = {}) {
  return (dispatch, getState) => {
    const queryKey = bookmarksQueryKey({ onlyMedia, withoutMedia, sortByPostDate });
    const list = getState().getIn(['status_lists', listKey]);
    if (list?.get('isLoading') && list.get('queryKey') === queryKey) {
      return Promise.resolve();
    }

    dispatch(fetchBookmarkedStatusesRequest(listKey, queryKey, sortByPostDate));

    return api(getState).get(`/api/v1/bookmarks?${requestParams({ onlyMedia, withoutMedia, sortByPostDate })}`).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      const statuses = importStatuses(dispatch, response.data);
      dispatch(fetchBookmarkedStatusesSuccess(statuses, next ? next.uri : null, listKey, queryKey));
    }).catch(error => {
      dispatch(fetchBookmarkedStatusesFail(error, listKey, queryKey));
    });
  };
}

export function fetchBookmarkedStatusesRequest(listKey = DEFAULT_LIST_KEY, queryKey = null, sortByPostDate = false) {
  return {
    type: BOOKMARKED_STATUSES_FETCH_REQUEST,
    listKey,
    queryKey,
    sortByPostDate,
  };
}

export function fetchBookmarkedStatusesSuccess(statuses, next, listKey = DEFAULT_LIST_KEY, queryKey = null) {
  return {
    type: BOOKMARKED_STATUSES_FETCH_SUCCESS,
    statuses,
    next,
    listKey,
    queryKey,
  };
}

export function fetchBookmarkedStatusesFail(error, listKey = DEFAULT_LIST_KEY, queryKey = null) {
  return {
    type: BOOKMARKED_STATUSES_FETCH_FAIL,
    error,
    listKey,
    queryKey,
  };
}

export function expandBookmarkedStatuses({ listKey = DEFAULT_LIST_KEY } = {}) {
  return (dispatch, getState) => {
    const list = getState().getIn(['status_lists', listKey]);
    const url = list?.get('next');
    const queryKey = list?.get('queryKey');

    if (!url || list.get('isLoading')) {
      return Promise.resolve();
    }

    dispatch(expandBookmarkedStatusesRequest(listKey, queryKey));

    return api(getState).get(url).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      const statuses = importStatuses(dispatch, response.data);
      dispatch(expandBookmarkedStatusesSuccess(statuses, next ? next.uri : null, listKey, queryKey));
    }).catch(error => {
      dispatch(expandBookmarkedStatusesFail(error, listKey, queryKey));
    });
  };
}

export function expandBookmarkedStatusesRequest(listKey = DEFAULT_LIST_KEY, queryKey = null) {
  return {
    type: BOOKMARKED_STATUSES_EXPAND_REQUEST,
    listKey,
    queryKey,
  };
}

export function expandBookmarkedStatusesSuccess(statuses, next, listKey = DEFAULT_LIST_KEY, queryKey = null) {
  return {
    type: BOOKMARKED_STATUSES_EXPAND_SUCCESS,
    statuses,
    next,
    listKey,
    queryKey,
  };
}

export function expandBookmarkedStatusesFail(error, listKey = DEFAULT_LIST_KEY, queryKey = null) {
  return {
    type: BOOKMARKED_STATUSES_EXPAND_FAIL,
    error,
    listKey,
    queryKey,
  };
}
