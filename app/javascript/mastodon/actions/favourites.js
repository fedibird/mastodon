import { fetchRelationshipsSuccess, fetchRelationshipsFromStatuses } from './accounts';
import api, { getLinks } from '../api';
import { importFetchedStatuses, importFetchedAccounts } from './importer';

export const FAVOURITED_STATUSES_FETCH_REQUEST = 'FAVOURITED_STATUSES_FETCH_REQUEST';
export const FAVOURITED_STATUSES_FETCH_SUCCESS = 'FAVOURITED_STATUSES_FETCH_SUCCESS';
export const FAVOURITED_STATUSES_FETCH_FAIL = 'FAVOURITED_STATUSES_FETCH_FAIL';

export const FAVOURITED_STATUSES_EXPAND_REQUEST = 'FAVOURITED_STATUSES_EXPAND_REQUEST';
export const FAVOURITED_STATUSES_EXPAND_SUCCESS = 'FAVOURITED_STATUSES_EXPAND_SUCCESS';
export const FAVOURITED_STATUSES_EXPAND_FAIL = 'FAVOURITED_STATUSES_EXPAND_FAIL';

const DEFAULT_LIST_KEY = 'favourites';
let requestSequence = 0;

// A -> B -> A must not accept a stale response from the first A request.

// Each pinned column owns its query/cursor. Standalone modes also have separate
// cursors, so switching order cannot reuse an incompatible page.
export const favouritesListKey = (columnId, sortByPostDate = false) => (
  columnId ? `favourites:${columnId}` : (sortByPostDate ? 'favourites:status' : DEFAULT_LIST_KEY)
);

export const favouritesQueryKey = ({ onlyMedia = false, withoutMedia = false, sortByPostDate = false } = {}) => JSON.stringify({
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

export function fetchFavouritedStatuses({ listKey = DEFAULT_LIST_KEY, onlyMedia = false, withoutMedia = false, sortByPostDate = false } = {}) {
  return (dispatch, getState) => {
    const queryKey = favouritesQueryKey({ onlyMedia, withoutMedia, sortByPostDate });
    const list = getState().getIn(['status_lists', listKey]);
    if (list?.get('isLoading') && list.get('queryKey') === queryKey) {
      return Promise.resolve();
    }

    const requestId = ++requestSequence;
    dispatch(fetchFavouritedStatusesRequest(listKey, queryKey, sortByPostDate, requestId));

    return api(getState).get(`/api/v1/favourites?${requestParams({ onlyMedia, withoutMedia, sortByPostDate })}`).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      const statuses = importStatuses(dispatch, response.data);
      dispatch(fetchFavouritedStatusesSuccess(statuses, next ? next.uri : null, listKey, queryKey, requestId));
    }).catch(error => {
      dispatch(fetchFavouritedStatusesFail(error, listKey, queryKey, requestId));
    });
  };
}

export function fetchFavouritedStatusesRequest(listKey = DEFAULT_LIST_KEY, queryKey = null, sortByPostDate = false, requestId = null) {
  return {
    type: FAVOURITED_STATUSES_FETCH_REQUEST,
    listKey,
    queryKey,
    requestId,
    sortByPostDate,
    requestId,
    skipLoading: true,
  };
}

export function fetchFavouritedStatusesSuccess(statuses, next, listKey = DEFAULT_LIST_KEY, queryKey = null, requestId = null) {
  return {
    type: FAVOURITED_STATUSES_FETCH_SUCCESS,
    statuses,
    next,
    listKey,
    queryKey,
    requestId,
    skipLoading: true,
  };
}

export function fetchFavouritedStatusesFail(error, listKey = DEFAULT_LIST_KEY, queryKey = null, requestId = null) {
  return {
    type: FAVOURITED_STATUSES_FETCH_FAIL,
    error,
    listKey,
    queryKey,
    requestId,
    skipLoading: true,
  };
}

export function expandFavouritedStatuses({ listKey = DEFAULT_LIST_KEY } = {}) {
  return (dispatch, getState) => {
    const list = getState().getIn(['status_lists', listKey]);
    const url = list?.get('next');
    const queryKey = list?.get('queryKey');
    const requestId = list?.get('requestId');

    if (!url || list.get('isLoading')) {
      return Promise.resolve();
    }

    dispatch(expandFavouritedStatusesRequest(listKey, queryKey, requestId));

    return api(getState).get(url).then(response => {
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      const statuses = importStatuses(dispatch, response.data);
      dispatch(expandFavouritedStatusesSuccess(statuses, next ? next.uri : null, listKey, queryKey, requestId));
    }).catch(error => {
      dispatch(expandFavouritedStatusesFail(error, listKey, queryKey, requestId));
    });
  };
}

export function expandFavouritedStatusesRequest(listKey = DEFAULT_LIST_KEY, queryKey = null, requestId = null) {
  return {
    type: FAVOURITED_STATUSES_EXPAND_REQUEST,
    listKey,
    queryKey,
    requestId,
  };
}

export function expandFavouritedStatusesSuccess(statuses, next, listKey = DEFAULT_LIST_KEY, queryKey = null, requestId = null) {
  return {
    type: FAVOURITED_STATUSES_EXPAND_SUCCESS,
    statuses,
    next,
    listKey,
    queryKey,
    requestId,
  };
}

export function expandFavouritedStatusesFail(error, listKey = DEFAULT_LIST_KEY, queryKey = null, requestId = null) {
  return {
    type: FAVOURITED_STATUSES_EXPAND_FAIL,
    error,
    listKey,
    queryKey,
    requestId,
  };
}
