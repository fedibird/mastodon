import { Map as ImmutableMap, fromJS } from 'immutable';
import {
  POSTING_CONTEXT_REVALIDATION_FAIL,
  POSTING_CONTEXT_REVALIDATION_UPDATE,
} from '../actions/posting_context_revalidations';

const initialState = ImmutableMap();

const TERMINAL = {
  completed: true,
  partial: true,
  failed: true,
};

const ACTIVE = {
  queued: true,
  running: true,
  idle: true,
};

const recordFrom = (accountId, data, extra = {}) => fromJS({
  accountId: String(accountId),
  state: (data && data.state) || 'idle',
  requestId: data && (data.request_id || data.requestId) || null,
  actor: data && data.actor || null,
  affiliations: data && data.affiliations || null,
  error: null,
  explicit: false,
  polling: 'idle',
  ...extra,
});

const requestIdOf = data => data && (data.request_id || data.requestId);

// A late poll must not rewind a finished job or replace a newer request.
const stalePoll = (current, action) => {
  if (!action.fromPoll || !current) {
    return false;
  }

  const currentRequestId = current.get('requestId');
  const incomingRequestId = requestIdOf(action.data);

  if (currentRequestId && incomingRequestId && currentRequestId !== incomingRequestId) {
    return true;
  }

  return Boolean(TERMINAL[current.get('state')] && action.data && ACTIVE[action.data.state]);
};

export default function postingContextRevalidations(state = initialState, action) {
  switch (action.type) {
  case POSTING_CONTEXT_REVALIDATION_UPDATE: {
    const key = String(action.accountId);
    const current = state.get(key);

    if (action.pollingOnly) {
      if (!current) {
        return state;
      }

      return state.set(key, current.set('polling', action.polling));
    }

    if (stalePoll(current, action)) {
      return state;
    }

    return state.set(key, recordFrom(action.accountId, action.data, {
      explicit: action.explicit !== false,
      error: action.error || null,
      polling: action.polling || 'idle',
    }));
  }
  case POSTING_CONTEXT_REVALIDATION_FAIL:
    return state.set(String(action.accountId), recordFrom(action.accountId, state.get(String(action.accountId)) && state.get(String(action.accountId)).toJS(), {
      explicit: true,
      error: action.error || 'failed',
      polling: 'idle',
    }));
  default:
    return state;
  }
}
