import { Map as ImmutableMap } from 'immutable';
import {
  USER_PREFERENCES_AUTHORIZATION_BLOCKED,
  USER_PREFERENCES_CONNECTED,
  USER_PREFERENCES_DISCONNECTED,
  USER_PREFERENCES_EVENT,
  USER_PREFERENCES_FETCH_FAIL,
  USER_PREFERENCES_FETCH_REQUEST,
  USER_PREFERENCES_FETCH_SUCCESS,
  USER_PREFERENCES_REFETCH_NEEDED,
  USER_PREFERENCES_UNSUBSCRIBED,
  isCanonicalDecimalRevision,
} from '../actions/user_preferences';

// Kept apart from Web::Setting `settings` and from composer state.
// `document` is the last successful GET body, stored without rewriting
// Reader fields. `lastEventRevision` is the highest accepted
// preferences_changed revision, compared as decimal text. GET does not
// return a revision, so this string is not the revision of `document`.
// `issuedSerial` is the last serial handed out by this store and is not
// cleared on unmount. A result is applied only when it is that latest
// request and newer than `acceptedSerial`, so a previous subscription
// cannot settle state for a serial the current subscription has replaced.
const initialState = ImmutableMap({
  document: null,
  loading: false,
  error: null,
  connected: false,
  lastEventRevision: null,
  refetchNeeded: false,
  authorizationBlocked: false,
  issuedSerial: 0,
  acceptedSerial: 0,
});

// browserslist includes iOS >= 9, and BigInt starts at Safari 14. Compare
// canonical decimal strings by length, then by code unit. No Number or BigInt.
const revisionOrder = (left, right) => {
  if (left.length !== right.length) {
    return left.length < right.length ? -1 : 1;
  }

  if (left < right) {
    return -1;
  }

  if (left > right) {
    return 1;
  }

  return 0;
};

const settleable = (state, serial) => (
  Number.isInteger(serial) &&
  serial === state.get('issuedSerial') &&
  serial > state.get('acceptedSerial')
);

export default function userPreferences(state = initialState, action) {
  switch (action.type) {
  case USER_PREFERENCES_CONNECTED:
    return state.set('connected', true);
  case USER_PREFERENCES_DISCONNECTED:
    return state.set('connected', false);
  case USER_PREFERENCES_UNSUBSCRIBED:
    return state.withMutations(map => {
      map.set('connected', false);
      map.set('loading', false);
      map.set('refetchNeeded', false);
    });
  case USER_PREFERENCES_EVENT:
    if (!isCanonicalDecimalRevision(action.revision)) {
      return state;
    }

    if (state.get('lastEventRevision') && revisionOrder(action.revision, state.get('lastEventRevision')) <= 0) {
      return state;
    }

    return state.set('lastEventRevision', action.revision);
  case USER_PREFERENCES_REFETCH_NEEDED:
    return state.set('refetchNeeded', true);
  case USER_PREFERENCES_FETCH_REQUEST:
    if (!Number.isInteger(action.serial) || action.serial <= state.get('issuedSerial')) {
      return state;
    }

    return state.withMutations(map => {
      map.set('loading', true);
      map.set('refetchNeeded', false);
      map.set('issuedSerial', action.serial);
    });
  case USER_PREFERENCES_FETCH_SUCCESS:
    if (!settleable(state, action.serial) || !action.document) {
      return state;
    }

    return state.withMutations(map => {
      map.set('document', action.document);
      map.set('loading', false);
      map.set('error', null);
      map.set('refetchNeeded', false);
      map.set('acceptedSerial', action.serial);
    });
  case USER_PREFERENCES_FETCH_FAIL:
    if (!settleable(state, action.serial)) {
      return state;
    }

    return state.withMutations(map => {
      map.set('loading', false);
      map.set('error', action.error);
      map.set('acceptedSerial', action.serial);

      if (action.error && action.error.kind === 'authorization') {
        map.set('authorizationBlocked', true);
        map.set('refetchNeeded', false);
      }
    });
  case USER_PREFERENCES_AUTHORIZATION_BLOCKED:
    return state.withMutations(map => {
      map.set('authorizationBlocked', true);
      map.set('loading', false);
      map.set('refetchNeeded', false);
      map.set('error', { kind: 'authorization', status: action.status });
    });
  default:
    return state;
  }
}
