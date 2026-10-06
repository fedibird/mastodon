import api from '../api';
import { selectPostingContextDiscovery } from '../selectors/posting_contexts';

export const POSTING_CONTEXT_FETCH_REQUEST = 'POSTING_CONTEXT_FETCH_REQUEST';
export const POSTING_CONTEXT_FETCH_SUCCESS = 'POSTING_CONTEXT_FETCH_SUCCESS';
export const POSTING_CONTEXT_FETCH_FAIL    = 'POSTING_CONTEXT_FETCH_FAIL';

const CACHED_STATUSES = ['loading', 'resolved', 'unsupported', 'not_applicable'];

const fetchPostingContextRequest = accountId => ({
  type: POSTING_CONTEXT_FETCH_REQUEST,
  accountId,
  skipLoading: true,
});

const fetchPostingContextSuccess = (accountId, data) => ({
  type: POSTING_CONTEXT_FETCH_SUCCESS,
  accountId,
  data,
  skipLoading: true,
});

const fetchPostingContextFail = (accountId, error) => ({
  type: POSTING_CONTEXT_FETCH_FAIL,
  accountId,
  error,
  skipLoading: true,
  skipAlert: true,
});

export function fetchPostingContext(accountId) {
  return (dispatch, getState) => {
    const current = selectPostingContextDiscovery(getState(), accountId);

    if (current && CACHED_STATUSES.includes(current.get('status'))) {
      return Promise.resolve();
    }

    dispatch(fetchPostingContextRequest(String(accountId)));

    return api(getState)
      .get(`/api/v1/fedibird/accounts/${encodeURIComponent(accountId)}/posting_context`)
      .then(({ data }) => {
        dispatch(fetchPostingContextSuccess(String(accountId), data));
      })
      .catch(error => {
        dispatch(fetchPostingContextFail(String(accountId), error));
      });
  };
}
