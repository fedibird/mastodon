import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import {
  POSTING_IDENTITIES_FETCH_FAIL,
  POSTING_IDENTITIES_FETCH_REQUEST,
  POSTING_IDENTITIES_FETCH_SUCCESS,
} from '../actions/posting_identities';

const initialState = ImmutableMap({
  status: 'idle',
  defaultIdentityId: null,
  identities: ImmutableList(),
});

const identityList = identities => {
  if (!identities) {
    return ImmutableList();
  }

  if (ImmutableList.isList(identities)) {
    return identities;
  }

  return ImmutableList(identities);
};

export default function postingIdentities(state = initialState, action) {
  switch (action.type) {
  case POSTING_IDENTITIES_FETCH_REQUEST:
    return state.set('status', 'loading');
  case POSTING_IDENTITIES_FETCH_SUCCESS:
    return state.merge({
      status: 'ready',
      defaultIdentityId: action.defaultIdentityId || null,
      identities: identityList(action.identities),
    });
  case POSTING_IDENTITIES_FETCH_FAIL:
    return state.merge({
      status: 'failed',
      defaultIdentityId: null,
      identities: ImmutableList(),
    });
  default:
    return state;
  }
}
