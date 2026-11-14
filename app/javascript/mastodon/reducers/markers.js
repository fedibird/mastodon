import compareId from '../compare_id';
import {
  MARKERS_FETCH_SUCCESS,
  MARKERS_SUBMIT_SUCCESS,
} from '../actions/markers';

const initialState = ImmutableMap({
  home: '0',
  notifications: '0',
});

import { Map as ImmutableMap } from 'immutable';

// Keep the last acknowledged server position monotonic even when an older
// GET response or a previously submitted POST completes out of order.
const adoptMarker = (state, timeline, value) => {
  if (value === undefined || value === null) {
    return state;
  }

  const id = String(value);
  return compareId(id, state.get(timeline, '0')) > 0 ? state.set(timeline, id) : state;
};

export default function markers(state = initialState, action) {
  switch(action.type) {
  case MARKERS_FETCH_SUCCESS:
    return adoptMarker(state, 'notifications', action.markers?.notifications?.last_read_id);
  case MARKERS_SUBMIT_SUCCESS:
    return adoptMarker(adoptMarker(state, 'home', action.home), 'notifications', action.notifications);
  default:
    return state;
  }
};
