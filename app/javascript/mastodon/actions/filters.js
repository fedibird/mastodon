import api from '../api';

import { importFilters } from './importer';
import { openModal } from './modal';
import { fetchStatus } from './statuses';

export { FILTERS_FETCH_REQUEST, FILTERS_FETCH_SUCCESS, FILTERS_FETCH_FAIL, fetchFilters, scheduleFiltersRefresh } from './filter_definitions';

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
