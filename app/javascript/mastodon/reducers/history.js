import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';

import { HISTORY_FETCH_REQUEST, HISTORY_FETCH_SUCCESS, HISTORY_FETCH_FAIL } from '../actions/history';

const initialHistory = ImmutableMap({
  loading: false,
  items: ImmutableList(),
});

const initialState = ImmutableMap();

export default function history(state = initialState, action) {
  switch(action.type) {
  case HISTORY_FETCH_REQUEST:
    return state.update(action.statusId, initialHistory, history => history.withMutations(map => {
      map.set('loading', true);
      map.set('items', ImmutableList());
    }));
  case HISTORY_FETCH_SUCCESS:
    return state.update(action.statusId, initialHistory, history => history.withMutations(map => {
      map.set('loading', false);
      map.set('items', fromJS((action.history || []).map((item, index) => ({
        ...item,
        account: item.account ? item.account.id : null,
        original: index === 0,
      })).reverse()));
    }));
  case HISTORY_FETCH_FAIL:
    return state.update(action.statusId, initialHistory, history => history.set('loading', false));
  default:
    return state;
  }
}
