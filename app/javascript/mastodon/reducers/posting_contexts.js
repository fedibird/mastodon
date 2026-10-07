import { Map as ImmutableMap, fromJS } from 'immutable';
import {
  POSTING_CONTEXT_FETCH_FAIL,
  POSTING_CONTEXT_FETCH_REQUEST,
  POSTING_CONTEXT_FETCH_SUCCESS,
} from '../actions/posting_contexts';
import { normalizePostingContextDiscovery } from '../posting_context/normalize';

const initialState = ImmutableMap();

const record = ({ status, context = null, discovery = null, reason = null, error = null, viewerEvidence = null, receivedAt = null }) => fromJS({
  status,
  context,
  discovery,
  reason,
  error,
  viewerEvidence,
  receivedAt,
});

export default function postingContexts(state = initialState, action) {
  switch (action.type) {
  case POSTING_CONTEXT_FETCH_REQUEST:
    return state.set(action.accountId, record({ status: 'loading' }));
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
  case POSTING_CONTEXT_FETCH_FAIL:
    return state.set(action.accountId, record({
      status: 'error',
      error: true,
    }));
  default:
    return state;
  }
}
