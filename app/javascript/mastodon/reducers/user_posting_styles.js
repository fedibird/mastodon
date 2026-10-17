import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import {
  USER_POSTING_STYLES_FETCH_FAIL,
  USER_POSTING_STYLES_FETCH_REQUEST,
  USER_POSTING_STYLES_FETCH_SUCCESS,
} from '../actions/user_posting_styles';

const initialState = ImmutableMap({
  status: 'idle',
  styles: ImmutableList(),
  requestId: 0,
  loaded: false,
  refreshing: false,
  refreshFailed: false,
});

export default function userPostingStyles(state = initialState, action) {
  switch (action.type) {
  case USER_POSTING_STYLES_FETCH_REQUEST:
    return state.merge({ status: state.get('loaded') ? 'ready' : 'loading', requestId: action.requestId === undefined ? state.get('requestId') : action.requestId, refreshing: true, refreshFailed: false });
  case USER_POSTING_STYLES_FETCH_SUCCESS:
    if (action.requestId !== undefined && action.requestId !== state.get('requestId')) return state;
    return state.merge({ status: 'ready', loaded: true, refreshing: false, refreshFailed: false, styles: ImmutableList(action.styles || []) });
  case USER_POSTING_STYLES_FETCH_FAIL:
    if (action.requestId !== undefined && action.requestId !== state.get('requestId')) return state;
    return state.merge({ status: state.get('loaded') ? 'ready' : 'failed', refreshing: false, refreshFailed: true });
  default:
    return state;
  }
}
