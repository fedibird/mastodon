import { Map as ImmutableMap, fromJS } from 'immutable';
import {
  POSTING_CONTEXT_FETCH_FAIL,
  POSTING_CONTEXT_FETCH_REQUEST,
  POSTING_CONTEXT_FETCH_SUCCESS,
} from '../actions/posting_contexts';
import { normalizePostingContextDiscovery } from '../posting_context/normalize';

const initialState = ImmutableMap();

// Successful discoveries stay in place across a later request. Permission
// freshness is a separate decision from keeping this context available.
const RETAINED_STATUSES = ['resolved', 'unsupported', 'not_applicable'];

const record = ({
  status,
  context = null,
  discovery = null,
  reason = null,
  error = null,
  viewerEvidence = null,
  senderPosting = null,
  receivedAt = null,
  refreshing = false,
  refreshError = null,
}) => fromJS({
  status,
  context,
  discovery,
  reason,
  error,
  viewerEvidence,
  senderPosting,
  receivedAt,
  refreshing,
  refreshError,
});

const retainedResult = current => (
  Boolean(current && current.get && RETAINED_STATUSES.includes(current.get('status')))
);

const cacheKeyFor = action => action.cacheKey || action.accountId;

export default function postingContexts(state = initialState, action) {
  switch (action.type) {
  case POSTING_CONTEXT_FETCH_REQUEST: {
    const cacheKey = cacheKeyFor(action);
    const current = state.get(cacheKey);

    if (retainedResult(current)) {
      return state.set(cacheKey, current.set('refreshing', true).set('refreshError', null));
    }

    return state.set(cacheKey, record({ status: 'loading' }));
  }
  case POSTING_CONTEXT_FETCH_SUCCESS: {
    const normalized = normalizePostingContextDiscovery(action.data) || {};

    return state.set(cacheKeyFor(action), record({
      status: normalized.status,
      context: normalized.context,
      discovery: normalized.discovery,
      reason: normalized.reason,
      viewerEvidence: normalized.viewerEvidence,
      senderPosting: normalized.senderPosting,
      receivedAt: action.receivedAt,
    }));
  }
  case POSTING_CONTEXT_FETCH_FAIL: {
    const cacheKey = cacheKeyFor(action);
    const current = state.get(cacheKey);

    if (current && current.get('refreshing') && retainedResult(current)) {
      return state.set(cacheKey, current.set('refreshing', false).set('refreshError', true));
    }

    return state.set(cacheKey, record({
      status: 'error',
      error: true,
    }));
  }
  default:
    return state;
  }
}
