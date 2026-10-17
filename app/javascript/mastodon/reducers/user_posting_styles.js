import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import {
  USER_POSTING_STYLES_FETCH_FAIL,
  USER_POSTING_STYLES_FETCH_REQUEST,
  USER_POSTING_STYLES_FETCH_SUCCESS,
} from '../actions/user_posting_styles';

const initialState = ImmutableMap({
  status: 'idle',
  styles: ImmutableList(),
});

export default function userPostingStyles(state = initialState, action) {
  switch (action.type) {
  case USER_POSTING_STYLES_FETCH_REQUEST:
    return state.set('status', 'loading').set('requestId', action.requestId);
  case USER_POSTING_STYLES_FETCH_SUCCESS:
    if (action.requestId !== state.get('requestId')) return state;
    return state.set('status', 'ready').set('hasLoaded', true).set('styles', ImmutableList(action.styles || []));
  case USER_POSTING_STYLES_FETCH_FAIL:
    if (action.requestId !== state.get('requestId')) return state;
    return state.set('status', 'failed');
  default:
    return state;
  }
}
