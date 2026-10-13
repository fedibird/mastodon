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
} from '../actions/user_preferences';

// Kept apart from Web::Setting `settings` and from composer state.
// `document` is the last successful GET body, stored without rewriting
// Reader fields. `lastEventRevision` is only the latest accepted
// preferences_changed revision. GET does not return a revision, so this
// string is not the revision of `document`. `acceptedSerial` drops an older
// HTTP result after a newer request has already settled.
const initialState = ImmutableMap({
  document: null,
  loading: false,
  error: null,
  connected: false,
  lastEventRevision: null,
  refetchNeeded: false,
  authorizationBlocked: false,
  acceptedSerial: 0,
});

const DECIMAL_REVISION = /^[0-9]+$/;

const newerSerial = (state, serial) => Number.isInteger(serial) && serial > state.get('acceptedSerial');

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
    if (typeof action.revision !== 'string' || !DECIMAL_REVISION.test(action.revision)) {
      return state;
    }

    return state.set('lastEventRevision', action.revision);
  case USER_PREFERENCES_REFETCH_NEEDED:
    return state.set('refetchNeeded', true);
  case USER_PREFERENCES_FETCH_REQUEST:
    return state.set('loading', true).set('refetchNeeded', false);
  case USER_PREFERENCES_FETCH_SUCCESS:
    if (!newerSerial(state, action.serial) || !action.document) {
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
    if (!newerSerial(state, action.serial)) {
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
