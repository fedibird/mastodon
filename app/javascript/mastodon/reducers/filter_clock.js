import { FILTERS_EXPIRY_TICK } from '../actions/filter_expiry';

// A tick has to change root state. react-redux skips mapState when the root
// state reference is unchanged, so an action every reducer ignores never
// re-renders a connected status. The count is not a timestamp: expiry still
// uses Date.now() inside getFilters, and this value only wakes that check.
// Timelines, unread counts, and filter reconciliation do not read it.
export default function filterClock(state = 0, action) {
  if (action.type !== FILTERS_EXPIRY_TICK) {
    return state;
  }

  return state + 1;
}
