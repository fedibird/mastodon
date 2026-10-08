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
  receivedAt,
  refreshing,
  refreshError,
});

const retainedResult = current => (
  Boolean(current && current.get && RETAINED_STATUSES.includes(current.get('status')))
);

export default function postingContexts(state = initialState, action) {
  switch (action.type) {
  case POSTING_CONTEXT_FETCH_REQUEST: {
    const current = state.get(action.accountId);

    if (retainedResult(current)) {
      return state.set(action.accountId, current.set('refreshing', true).set('refreshError', null));
    }

    return state.set(action.accountId, record({ status: 'loading' }));
  }
  case POSTING_CONTEXT_FETCH_SUCCESS: {
    const normalized = normalizePostingContextDiscovery(action.data) || {};

    return state.set(action.accountId, record({
      status: normalized.status,
      context: normalized.context,
      discovery: normalized.discovery,
      reason: normalized.reason,
      viewerEvidence: normalized.viewerEvidence,
      receivedAt: action.receivedAt,
    }));
  }
  case POSTING_CONTEXT_FETCH_FAIL: {
    const current = state.get(action.accountId);

    if (current && current.get('refreshing') && retainedResult(current)) {
      return state.set(action.accountId, current.set('refreshing', false).set('refreshError', true));
    }

    return state.set(action.accountId, record({
      status: 'error',
      error: true,
    }));
  }
  default:
    return state;
  }
}
