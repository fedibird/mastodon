import api from '../api';
import { selectPostingContextDiscovery } from '../selectors/posting_contexts';

export const POSTING_CONTEXT_FETCH_REQUEST = 'POSTING_CONTEXT_FETCH_REQUEST';
export const POSTING_CONTEXT_FETCH_SUCCESS = 'POSTING_CONTEXT_FETCH_SUCCESS';
export const POSTING_CONTEXT_FETCH_FAIL    = 'POSTING_CONTEXT_FETCH_FAIL';

// How long a discovery REST result stays reusable in this session.
// This is separate from the server affiliation snapshot freshness.
export const POSTING_CONTEXT_CACHE_TTL = 5 * 60 * 1000;

const SUCCESS_STATUSES = ['resolved', 'unsupported', 'not_applicable'];

const fetchPostingContextRequest = accountId => ({
  type: POSTING_CONTEXT_FETCH_REQUEST,
  accountId,
  skipLoading: true,
});

const fetchPostingContextSuccess = (accountId, data, receivedAt) => ({
  type: POSTING_CONTEXT_FETCH_SUCCESS,
  accountId,
  data,
  receivedAt,
  skipLoading: true,
});

const fetchPostingContextFail = (accountId, error) => ({
  type: POSTING_CONTEXT_FETCH_FAIL,
  accountId,
  error,
  skipLoading: true,
  skipAlert: true,
});

const inflightDiscoveries = new Map();

const successCacheIsFresh = (current, now) => {
  if (!current || !SUCCESS_STATUSES.includes(current.get('status'))) {
    return false;
  }

  const receivedAt = current.get('receivedAt');

  return typeof receivedAt === 'number' && (now - receivedAt) < POSTING_CONTEXT_CACHE_TTL;
};

export function fetchPostingContext(accountId, { force = false } = {}) {
  return (dispatch, getState) => {
    const id = String(accountId);
    const current = selectPostingContextDiscovery(getState(), id);

    if (inflightDiscoveries.has(id)) {
      return inflightDiscoveries.get(id);
    }

    if (!force && successCacheIsFresh(current, Date.now())) {
      return Promise.resolve();
    }

    dispatch(fetchPostingContextRequest(id));

    const pending = api(getState)
      .get(`/api/v1/fedibird/accounts/${encodeURIComponent(id)}/posting_context`)
      .then(({ data }) => {
        dispatch(fetchPostingContextSuccess(id, data, Date.now()));
      })
      .catch(error => {
        dispatch(fetchPostingContextFail(id, error));
      })
      .finally(() => {
        inflightDiscoveries.delete(id);
      });

    inflightDiscoveries.set(id, pending);

    return pending;
  };
}
