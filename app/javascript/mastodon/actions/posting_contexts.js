import api from '../api';
import { postingContextCacheKey, selectPostingContextDiscovery } from '../selectors/posting_contexts';

export const POSTING_CONTEXT_FETCH_REQUEST = 'POSTING_CONTEXT_FETCH_REQUEST';
export const POSTING_CONTEXT_FETCH_SUCCESS = 'POSTING_CONTEXT_FETCH_SUCCESS';
export const POSTING_CONTEXT_FETCH_FAIL    = 'POSTING_CONTEXT_FETCH_FAIL';

// How long a discovery REST result stays reusable in this session.
// This is separate from the server affiliation snapshot freshness.
export const POSTING_CONTEXT_CACHE_TTL = 5 * 60 * 1000;

const SUCCESS_STATUSES = ['resolved', 'unsupported', 'not_applicable'];

const fetchPostingContextRequest = (accountId, cacheKey) => ({
  type: POSTING_CONTEXT_FETCH_REQUEST,
  accountId,
  cacheKey,
  skipLoading: true,
});

const fetchPostingContextSuccess = (accountId, cacheKey, data, receivedAt) => ({
  type: POSTING_CONTEXT_FETCH_SUCCESS,
  accountId,
  cacheKey,
  data,
  receivedAt,
  skipLoading: true,
});

const fetchPostingContextFail = (accountId, cacheKey, error) => ({
  type: POSTING_CONTEXT_FETCH_FAIL,
  accountId,
  cacheKey,
  error,
  skipLoading: true,
  skipAlert: true,
});

const inflightDiscoveries = new Map();

const successCacheIsFresh = (current, now) => {
  if (!current || !SUCCESS_STATUSES.includes(current.get('status'))) {
    return false;
  }

  // A failed refresh must be retryable even while receivedAt is inside the TTL.
  if (current.get('refreshError') || current.get('refreshing')) {
    return false;
  }

  const receivedAt = current.get('receivedAt');

  return typeof receivedAt === 'number' && (now - receivedAt) < POSTING_CONTEXT_CACHE_TTL;
};

const discoveryInFlight = current => (
  Boolean(current && (current.get('status') === 'loading' || current.get('refreshing')))
);

export function fetchPostingContext(accountId, { force = false, identityId = null, delegationId = null } = {}) {
  return (dispatch, getState) => {
    const id = String(accountId);
    const delegated = identityId && !String(identityId).startsWith('local:');
    const identity = delegated ? { identityId: String(identityId), delegationId: delegationId || '' } : null;
    const cacheKey = postingContextCacheKey(id, identity);
    const current = selectPostingContextDiscovery(getState(), id, identity);

    if (inflightDiscoveries.has(cacheKey)) {
      return inflightDiscoveries.get(cacheKey);
    }

    if (discoveryInFlight(current)) {
      return Promise.resolve();
    }

    if (!force && successCacheIsFresh(current, Date.now())) {
      return Promise.resolve();
    }

    dispatch(fetchPostingContextRequest(id, cacheKey));

    const pending = api(getState)
      .get(`/api/v1/fedibird/accounts/${encodeURIComponent(id)}/posting_context`, {
        params: delegated ? { posting_identity_id: String(identityId) } : undefined,
      })
      .then(({ data }) => {
        dispatch(fetchPostingContextSuccess(id, cacheKey, data, Date.now()));
      })
      .catch(error => {
        dispatch(fetchPostingContextFail(id, cacheKey, error));
      })
      .finally(() => {
        inflightDiscoveries.delete(cacheKey);
      });

    inflightDiscoveries.set(cacheKey, pending);

    return pending;
  };
}
