import api from '../api';
import {
  importFetchedCustomEmojiDetail,
} from './importer';

export const CUSTOM_EMOJIS_FETCH_REQUEST = 'CUSTOM_EMOJIS_FETCH_REQUEST';
export const CUSTOM_EMOJIS_FETCH_SUCCESS = 'CUSTOM_EMOJIS_FETCH_SUCCESS';
export const CUSTOM_EMOJIS_FETCH_FAIL = 'CUSTOM_EMOJIS_FETCH_FAIL';
export const CUSTOM_EMOJI_DETAIL_FETCH_REQUEST = 'CUSTOM_EMOJI_DETAIL_FETCH_REQUEST';
export const CUSTOM_EMOJI_DETAIL_FETCH_SUCCESS = 'CUSTOM_EMOJI_DETAIL_FETCH_SUCCESS';
export const CUSTOM_EMOJI_DETAIL_FETCH_FAIL = 'CUSTOM_EMOJI_DETAIL_FETCH_FAIL';

// One network request shared by every store. Each store still dispatches the
// result into its own state. A rejected request is forgotten so the next
// caller can try again. A successful empty list stays cached.
let sharedRequest = null;
const requestsByState = new WeakMap();

function loadSharedCatalog(getState) {
  if (!sharedRequest) {
    sharedRequest = api(getState).get('/api/v1/custom_emojis').then(response => {
      return Array.isArray(response.data) ? response.data : [];
    }).catch(error => {
      sharedRequest = null;
      throw error;
    });
  }

  return sharedRequest;
}

export function ensureCustomEmojis() {
  return (dispatch, getState) => {
    const status = getState().getIn(['custom_emoji_catalog', 'status']);

    if (status === 'ready') {
      return Promise.resolve(getState().get('custom_emojis'));
    }

    const current = requestsByState.get(getState);

    if (current) {
      return current;
    }

    dispatch(fetchCustomEmojisRequest());

    const request = loadSharedCatalog(getState).then(customEmojis => {
      dispatch(fetchCustomEmojisSuccess(customEmojis));
      return customEmojis;
    }).catch(error => {
      dispatch(fetchCustomEmojisFail(error));
      throw error;
    }).finally(() => {
      if (requestsByState.get(getState) === request) {
        requestsByState.delete(getState);
      }
    });

    requestsByState.set(getState, request);
    return request;
  };
}

export function fetchCustomEmojis() {
  return ensureCustomEmojis();
}

export function resetCustomEmojiCatalogForTests() {
  sharedRequest = null;
}

export function fetchCustomEmojisRequest() {
  return {
    type: CUSTOM_EMOJIS_FETCH_REQUEST,
    skipLoading: true,
  };
};

export function fetchCustomEmojisSuccess(custom_emojis) {
  return {
    type: CUSTOM_EMOJIS_FETCH_SUCCESS,
    custom_emojis,
    skipLoading: true,
  };
};

export function fetchCustomEmojisFail(error) {
  return {
    type: CUSTOM_EMOJIS_FETCH_FAIL,
    error,
    skipLoading: true,
  };
};

export function fetchCustomEmojiDetail(shortcode_with_domain) {
  return (dispatch, getState) => {
    dispatch(fetchCustomEmojiDetailRequest());

    api(getState).post(`/api/v1/custom_emojis/${shortcode_with_domain}/fetch`).then(response => {
      dispatch(importFetchedCustomEmojiDetail(response.data));
      dispatch(fetchCustomEmojiDetailSuccess(response.data));
    }).catch(error => {
      dispatch(fetchCustomEmojiDetailFail(error));
    });
  };
}

export function fetchCustomEmojiDetailRequest() {
  return {
    type: CUSTOM_EMOJI_DETAIL_FETCH_REQUEST,
    skipLoading: true,
  };
};

export function fetchCustomEmojiDetailSuccess(custom_emojis) {
  return {
    type: CUSTOM_EMOJI_DETAIL_FETCH_SUCCESS,
    custom_emojis,
    skipLoading: true,
  };
};

export function fetchCustomEmojiDetailFail(error) {
  return {
    type: CUSTOM_EMOJI_DETAIL_FETCH_FAIL,
    error,
    skipLoading: true,
  };
};

