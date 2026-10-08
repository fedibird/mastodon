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
    return state.set('status', 'loading');
  case USER_POSTING_STYLES_FETCH_SUCCESS:
    return state.set('status', 'ready').set('styles', ImmutableList(action.styles || []));
  case USER_POSTING_STYLES_FETCH_FAIL:
    return state.set('status', 'failed').set('styles', ImmutableList());
  default:
    return state;
  }
}
