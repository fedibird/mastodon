import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import {
  POSTING_IDENTITIES_FETCH_FAIL,
  POSTING_IDENTITIES_FETCH_REQUEST,
  POSTING_IDENTITIES_FETCH_SUCCESS,
} from '../actions/posting_identities';

const initialState = ImmutableMap({
  status: 'idle',
  defaultIdentityId: null,
  confirmedIdentityId: null,
  identities: ImmutableList(),
});

export default function postingIdentities(state = initialState, action) {
  switch (action.type) {
  case POSTING_IDENTITIES_FETCH_REQUEST:
    return state.set('status', 'loading');
  case POSTING_IDENTITIES_FETCH_SUCCESS:
    return state
      .set('status', 'ready')
      .set('defaultIdentityId', action.defaultIdentityId || null)
      .set('confirmedIdentityId', action.confirmedIdentityId || null)
      .set('identities', ImmutableList(action.identities || []));
  case POSTING_IDENTITIES_FETCH_FAIL:
    return state
      .set('status', 'failed')
      .set('defaultIdentityId', null)
      .set('confirmedIdentityId', null)
      .set('identities', ImmutableList());
  default:
    return state;
  }
}
