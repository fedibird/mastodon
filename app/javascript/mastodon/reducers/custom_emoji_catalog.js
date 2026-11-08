import { Map as ImmutableMap } from 'immutable';
import {
  CUSTOM_EMOJIS_FETCH_FAIL,
  CUSTOM_EMOJIS_FETCH_REQUEST,
  CUSTOM_EMOJIS_FETCH_SUCCESS,
} from '../actions/custom_emojis';

const initialState = ImmutableMap({
  status: 'idle',
});

// Sibling of the custom_emojis list. The list stays an ImmutableList so
// existing consumers keep their type. idle is unfetched. ready includes a
// successful empty catalog. error can be requested again.
export default function customEmojiCatalog(state = initialState, action) {
  switch (action.type) {
  case CUSTOM_EMOJIS_FETCH_REQUEST:
    return state.set('status', 'loading');
  case CUSTOM_EMOJIS_FETCH_SUCCESS:
    return state.set('status', 'ready');
  case CUSTOM_EMOJIS_FETCH_FAIL:
    return state.set('status', 'error');
  default:
    return state;
  }
}
