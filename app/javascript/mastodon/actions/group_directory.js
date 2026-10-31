import api from '../api';
import { importFetchedAccounts } from './importer';
import { fetchRelationships } from './accounts';
import { groupDirectoryApiParams, groupDirectoryFilterKey } from '../features/group_directory/params';

export const GROUP_DIRECTORY_FETCH_REQUEST = 'GROUP_DIRECTORY_FETCH_REQUEST';
export const GROUP_DIRECTORY_FETCH_SUCCESS = 'GROUP_DIRECTORY_FETCH_SUCCESS';
export const GROUP_DIRECTORY_FETCH_FAIL    = 'GROUP_DIRECTORY_FETCH_FAIL';

export const GROUP_DIRECTORY_EXPAND_REQUEST = 'GROUP_DIRECTORY_EXPAND_REQUEST';
export const GROUP_DIRECTORY_EXPAND_SUCCESS = 'GROUP_DIRECTORY_EXPAND_SUCCESS';
export const GROUP_DIRECTORY_EXPAND_FAIL    = 'GROUP_DIRECTORY_EXPAND_FAIL';

export const GROUP_DIRECTORY_DISCARD = 'GROUP_DIRECTORY_DISCARD';

const requestIds = new Map();

const beginRequest = (viewKey) => {
  const requestId = (requestIds.get(viewKey) || 0) + 1;
  requestIds.set(viewKey, requestId);

  return requestId;
};

const stripDirectoryMetadata = (accounts) => accounts.map(account => {
  const copy = { ...account };
  delete copy.group_directory;

  return copy;
});

const finish = (dispatch, viewKey, filterKey, requestId, accounts, kind) => {
  if (requestIds.get(viewKey) !== requestId) {
    return;
  }

  const limit = groupDirectoryApiParams({}).limit;

  dispatch(importFetchedAccounts(stripDirectoryMetadata(accounts)));
  dispatch({
    type: kind === 'expand' ? GROUP_DIRECTORY_EXPAND_SUCCESS : GROUP_DIRECTORY_FETCH_SUCCESS,
    viewKey,
    filterKey,
    requestId,
    accounts,
    exhausted: accounts.length < limit,
  });
  dispatch(fetchRelationships(accounts.map(account => account.id)));
};

export const fetchGroupDirectory = (viewKey, params) => (dispatch, getState) => {
  const filterKey = groupDirectoryFilterKey(params);
  const requestId = beginRequest(viewKey);

  dispatch({
    type: GROUP_DIRECTORY_FETCH_REQUEST,
    viewKey,
    filterKey,
    requestId,
  });

  api(getState).get('/api/v1/group_directory', {
    params: groupDirectoryApiParams(params),
  }).then(({ data }) => {
    finish(dispatch, viewKey, filterKey, requestId, data, 'fetch');
  }).catch(error => {
    if (requestIds.get(viewKey) !== requestId) {
      return;
    }

    dispatch({
      type: GROUP_DIRECTORY_FETCH_FAIL,
      viewKey,
      filterKey,
      requestId,
      error,
    });
  });
};

export const expandGroupDirectory = (viewKey, params) => (dispatch, getState) => {
  const filterKey = groupDirectoryFilterKey(params);
  const list = getState().getIn(['user_lists', 'group_directories', viewKey]);

  if (!list || list.get('isLoading') || list.get('isExpanding') || list.get('exhausted') || list.get('error')) {
    return;
  }

  if (list.get('filterKey') !== filterKey) {
    return;
  }

  const requestId = beginRequest(viewKey);
  const offset = list.get('items').size;

  dispatch({
    type: GROUP_DIRECTORY_EXPAND_REQUEST,
    viewKey,
    filterKey,
    requestId,
  });

  api(getState).get('/api/v1/group_directory', {
    params: { ...groupDirectoryApiParams(params), offset },
  }).then(({ data }) => {
    finish(dispatch, viewKey, filterKey, requestId, data, 'expand');
  }).catch(error => {
    if (requestIds.get(viewKey) !== requestId) {
      return;
    }

    dispatch({
      type: GROUP_DIRECTORY_EXPAND_FAIL,
      viewKey,
      filterKey,
      requestId,
      error,
    });
  });
};

export const discardGroupDirectory = (viewKey) => {
  beginRequest(viewKey);

  return {
    type: GROUP_DIRECTORY_DISCARD,
    viewKey,
  };
};
