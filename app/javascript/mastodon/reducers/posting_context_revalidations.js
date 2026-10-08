import { Map as ImmutableMap, fromJS } from 'immutable';
import {
  POSTING_CONTEXT_REVALIDATION_FAIL,
  POSTING_CONTEXT_REVALIDATION_UPDATE,
} from '../actions/posting_context_revalidations';

const initialState = ImmutableMap();

const recordFrom = (accountId, data, extra = {}) => fromJS({
  accountId: String(accountId),
  state: (data && data.state) || 'idle',
  requestId: data && (data.request_id || data.requestId) || null,
  actor: data && data.actor || null,
  affiliations: data && data.affiliations || null,
  error: null,
  explicit: false,
  ...extra,
});

export default function postingContextRevalidations(state = initialState, action) {
  switch (action.type) {
  case POSTING_CONTEXT_REVALIDATION_UPDATE:
    return state.set(String(action.accountId), recordFrom(action.accountId, action.data, {
      explicit: action.explicit !== false,
      error: action.error || null,
    }));
  case POSTING_CONTEXT_REVALIDATION_FAIL:
    return state.set(String(action.accountId), recordFrom(action.accountId, state.get(String(action.accountId)) && state.get(String(action.accountId)).toJS(), {
      explicit: true,
      error: action.error || 'failed',
    }));
  default:
    return state;
  }
}
