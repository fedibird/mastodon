import { Map as ImmutableMap } from 'immutable';
import { STORE_HYDRATE } from '../actions/store';

const PERMITTED = 'EXTERNAL_FEEDS_PERMITTED';

const initialState = ImmutableMap({
  permitted: false,
});

export default function externalFeeds (state = initialState, action) {
  switch (action.type) {
  case STORE_HYDRATE:
    return state.set('permitted', action.state.getIn(['meta', 'external_feeds']) === true);
  case PERMITTED:
    return state.set('permitted', action.permitted === true);
  default:
    return state;
  }
}
