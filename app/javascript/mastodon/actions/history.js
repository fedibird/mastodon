import api from '../api';

import { importFetchedAccounts } from './importer';

export const HISTORY_FETCH_REQUEST = 'HISTORY_FETCH_REQUEST';
export const HISTORY_FETCH_SUCCESS = 'HISTORY_FETCH_SUCCESS';
export const HISTORY_FETCH_FAIL    = 'HISTORY_FETCH_FAIL';

export const fetchHistory = statusId => (dispatch, getState) => {
  const loading = getState().getIn(['history', statusId, 'loading']);

  if (loading) {
    return;
  }

  dispatch(fetchHistoryRequest(statusId));

  api(getState).get(`/api/v1/statuses/${statusId}/history`).then(({ data }) => {
    const revisions = Array.isArray(data) ? data : [];
    dispatch(importFetchedAccounts(revisions.map(item => item.account).filter(Boolean)));
    dispatch(fetchHistorySuccess(statusId, revisions));
  }).catch(error => {
    dispatch(fetchHistoryFail(statusId, error));
  });
};

export const fetchHistoryRequest = statusId => ({
  type: HISTORY_FETCH_REQUEST,
  statusId,
});

export const fetchHistorySuccess = (statusId, history) => ({
  type: HISTORY_FETCH_SUCCESS,
  statusId,
  history,
});

export const fetchHistoryFail = (statusId, error) => ({
  type: HISTORY_FETCH_FAIL,
  statusId,
  error,
});
