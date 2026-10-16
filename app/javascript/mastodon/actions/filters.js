import api from '../api';

import { importFilters } from './importer';
import { openModal } from './modal';
import { fetchStatus } from './statuses';

export const FILTERS_FETCH_REQUEST = 'FILTERS_FETCH_REQUEST';
export const FILTERS_FETCH_SUCCESS = 'FILTERS_FETCH_SUCCESS';
export const FILTERS_FETCH_FAIL    = 'FILTERS_FETCH_FAIL';

export const FILTERS_CREATE_REQUEST = 'FILTERS_CREATE_REQUEST';
export const FILTERS_CREATE_SUCCESS = 'FILTERS_CREATE_SUCCESS';
export const FILTERS_CREATE_FAIL    = 'FILTERS_CREATE_FAIL';

export const FILTERS_STATUS_CREATE_REQUEST = 'FILTERS_STATUS_CREATE_REQUEST';
export const FILTERS_STATUS_CREATE_SUCCESS = 'FILTERS_STATUS_CREATE_SUCCESS';
export const FILTERS_STATUS_CREATE_FAIL    = 'FILTERS_STATUS_CREATE_FAIL';

export const initAddFilter = (status, { contextType } = {}) => dispatch =>
  dispatch(openModal('FILTER', {
    statusId: status?.get('id'),
    contextType,
  }));

// An earlier load/stream refresh must not overwrite a post-commit collection.
const latestFilterFetch = new WeakMap();

const streamRefreshes = new WeakMap();

// One timer and one in-flight stream refresh per store. Continuous events
// coalesce into a single trailing refresh; errors do not trigger retries.
export const scheduleFiltersRefresh = () => dispatch => {
  let refresh = streamRefreshes.get(dispatch);
  if (!refresh) {
    refresh = { dirty: false, timer: null, pending: false };
    streamRefreshes.set(dispatch, refresh);
  }
  refresh.dirty = true;
  const schedule = () => {
    if (refresh.timer !== null || refresh.pending) return;
    refresh.timer = setTimeout(async () => {
      refresh.timer = null;
      refresh.pending = true;
      refresh.dirty = false;
      try {
        await dispatch(fetchFilters());
      } finally {
        refresh.pending = false;
        if (refresh.dirty) schedule();
        else streamRefreshes.delete(dispatch);
      }
    }, 250);
  };
  schedule();
};

export const fetchFilters = () => (dispatch, getState) => {
  const request = {};
  latestFilterFetch.set(dispatch, request);
  dispatch({
    type: FILTERS_FETCH_REQUEST,
    skipLoading: true,
  });

  return api(getState)
    .get('/api/v2/filters')
    .then(({ data }) => {
      if (latestFilterFetch.get(dispatch) !== request) return;
      // FILTERS_FETCH_SUCCESS replaces the collection. A preceding
      // FILTERS_IMPORT merge would be overwritten on the next dispatch.
      dispatch({
        type: FILTERS_FETCH_SUCCESS,
        filters: data,
        skipLoading: true,
      });
    })
    .catch(err => {
      if (latestFilterFetch.get(dispatch) !== request) return;
      dispatch({ type: FILTERS_FETCH_FAIL, err, skipLoading: true, skipAlert: true });
    });
};

export const createFilter = (params, onSuccess, onFail) => (dispatch, getState) => {
  dispatch(createFilterRequest());

  return api(getState).post('/api/v2/filters', params).then(response => {
    // FILTERS_CREATE_* drives the loading bar; the filters reducer ignores
    // it. Merge the created entity so the modal can select it immediately.
    dispatch(importFilters([response.data]));
    dispatch(createFilterSuccess(response.data));
    if (onSuccess) onSuccess(response.data);
  }).catch(error => {
    dispatch(createFilterFail(error));
    if (onFail) onFail(error);
  });
};

export const createFilterRequest = () => ({
  type: FILTERS_CREATE_REQUEST,
});

export const createFilterSuccess = filter => ({
  type: FILTERS_CREATE_SUCCESS,
  filter,
});

export const createFilterFail = error => ({
  type: FILTERS_CREATE_FAIL,
  error,
});

export const createFilterStatus = (params, onSuccess, onFail) => (dispatch, getState) => {
  dispatch(createFilterStatusRequest());

  return api(getState).post(`/api/v2/filters/${params.filter_id}/statuses`, {
    status_id: params.status_id,
  }).then(response => {
    dispatch(createFilterStatusSuccess(response.data));
    dispatch(fetchStatus(params.status_id, true));
    if (onSuccess) onSuccess(response.data);
  }).catch(error => {
    dispatch(createFilterStatusFail(error));
    if (onFail) onFail(error);
  });
};

export const createFilterStatusRequest = () => ({
  type: FILTERS_STATUS_CREATE_REQUEST,
});

export const createFilterStatusSuccess = filterStatus => ({
  type: FILTERS_STATUS_CREATE_SUCCESS,
  filter_status: filterStatus,
});

export const createFilterStatusFail = error => ({
  type: FILTERS_STATUS_CREATE_FAIL,
  error,
});
