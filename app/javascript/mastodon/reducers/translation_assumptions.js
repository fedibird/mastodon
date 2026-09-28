import { Map as ImmutableMap, fromJS } from 'immutable';
import { STATUS_TRANSLATION_ASSUMPTION } from '../actions/statuses';
import { TIMELINE_DELETE } from '../actions/timelines';

const deleteAssumption = (state, id, references) => {
  let next = state.delete(id);

  references?.forEach(ref => {
    next = next.delete(ref);
  });

  return next;
};

const initialState = ImmutableMap();

export default function translationAssumptions(state = initialState, action) {
  switch(action.type) {
  case STATUS_TRANSLATION_ASSUMPTION:
    return state.set(action.id, fromJS({ source: action.source, target: action.target }));
  case TIMELINE_DELETE:
    return deleteAssumption(state, action.id, action.references);
  default:
    return state;
  }
}
