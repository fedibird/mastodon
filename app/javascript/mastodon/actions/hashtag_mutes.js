import api from '../api';

import { fetchFilters } from './filter_definitions';
import { armFilterExpiry } from './filter_expiry';
import { importFilters } from './importer';

export const HASHTAG_MUTE_REQUEST = 'HASHTAG_MUTE_REQUEST';
export const HASHTAG_MUTE_SUCCESS = 'HASHTAG_MUTE_SUCCESS';
export const HASHTAG_MUTE_FAIL    = 'HASHTAG_MUTE_FAIL';

const refreshAfterChange = (dispatch, getState, filter) => {
  if (filter) {
    dispatch(importFilters([filter]));
  }

  armFilterExpiry(dispatch, getState);
  return dispatch(fetchFilters());
};

export const muteHashtag = (name, expiresIn) => (dispatch, getState) => {
  dispatch({ type: HASHTAG_MUTE_REQUEST, skipLoading: true });

  const payload = { name };

  if (expiresIn) {
    payload.expires_in = expiresIn;
  }

  return api(getState).post('/api/v1/hashtag_mutes', payload).then(response => {
    dispatch({ type: HASHTAG_MUTE_SUCCESS, filter: response.data, skipLoading: true });
    return refreshAfterChange(dispatch, getState, response.data);
  }).catch(error => {
    dispatch({ type: HASHTAG_MUTE_FAIL, error });
    throw error;
  });
};

export const updateHashtagMute = (id, expiresIn) => (dispatch, getState) => {
  dispatch({ type: HASHTAG_MUTE_REQUEST, skipLoading: true });

  return api(getState).put(`/api/v1/hashtag_mutes/${id}`, {
    expires_in: expiresIn || null,
  }).then(response => {
    dispatch({ type: HASHTAG_MUTE_SUCCESS, filter: response.data, skipLoading: true });
    return refreshAfterChange(dispatch, getState, response.data);
  }).catch(error => {
    dispatch({ type: HASHTAG_MUTE_FAIL, error });
    throw error;
  });
};

export const unmuteHashtag = id => (dispatch, getState) => {
  dispatch({ type: HASHTAG_MUTE_REQUEST, skipLoading: true });

  return api(getState).delete(`/api/v1/hashtag_mutes/${id}`).then(() => {
    dispatch({ type: HASHTAG_MUTE_SUCCESS, skipLoading: true });
    return refreshAfterChange(dispatch, getState, null);
  }).catch(error => {
    dispatch({ type: HASHTAG_MUTE_FAIL, error });
    throw error;
  });
};
