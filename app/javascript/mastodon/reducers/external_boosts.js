import { OrderedMap, Map as ImmutableMap } from 'immutable';
import compareId from '../compare_id';
import { EXTERNAL_LINK_BOOST_CHANGED } from '../actions/external_boosts';
import { FLOOR_LIMIT } from '../external_boosts/revision';

// The newest (revision, reblogged) a stream event reported per projection id.
// It exists so that a status that is not held yet cannot be imported with an
// older pair. It is bounded, newest last, and lives only as long as the page.
const initialState = OrderedMap();

export default function externalBoosts(state = initialState, action) {
  switch (action.type) {
  case EXTERNAL_LINK_BOOST_CHANGED: {
    const current = state.get(action.statusId);

    if (current && compareId(action.revision, current.get('revision')) <= 0) {
      return state;
    }

    let next = state.delete(action.statusId).set(action.statusId, ImmutableMap({ revision: action.revision, reblogged: action.reblogged }));

    while (next.size > FLOOR_LIMIT) {
      next = next.delete(next.keySeq().first());
    }

    return next;
  }
  default:
    return state;
  }
};
