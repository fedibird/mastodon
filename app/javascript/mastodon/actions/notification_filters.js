import api from '../api';

export const NOTIFICATION_FILTERS_FETCH_REQUEST = 'NOTIFICATION_FILTERS_FETCH_REQUEST';
export const NOTIFICATION_FILTERS_FETCH_SUCCESS = 'NOTIFICATION_FILTERS_FETCH_SUCCESS';
export const NOTIFICATION_FILTERS_FETCH_FAIL    = 'NOTIFICATION_FILTERS_FETCH_FAIL';

// Temporary compatibility path for notifications until PR C migrates them
// to FilterResult. Timeline filtering must keep using state.filters (v2).
export const fetchNotificationFilters = () => (dispatch, getState) => {
  dispatch({
    type: NOTIFICATION_FILTERS_FETCH_REQUEST,
    skipLoading: true,
  });

  api(getState)
    .get('/api/v1/filters')
    .then(({ data }) => dispatch({
      type: NOTIFICATION_FILTERS_FETCH_SUCCESS,
      filters: data,
      skipLoading: true,
    }))
    .catch(err => dispatch({
      type: NOTIFICATION_FILTERS_FETCH_FAIL,
      err,
      skipLoading: true,
      skipAlert: true,
    }));
};
