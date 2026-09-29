import { Set as ImmutableSet } from 'immutable';
import { STATUS_TRANSLATION_BAR_REVEAL } from '../actions/translation_bar';
import { TIMELINE_DELETE } from '../actions/timelines';

const deleteOverride = (state, id, references) => {
  let next = state.delete(id);

  references?.forEach(ref => {
    next = next.delete(ref);
  });

  return next;
};

const initialState = ImmutableSet();

export default function translationBarOverrides(state = initialState, action) {
  switch(action.type) {
  case STATUS_TRANSLATION_BAR_REVEAL:
    return action.id ? state.add(action.id) : state;
  case TIMELINE_DELETE:
    return deleteOverride(state, action.id, action.references);
  default:
    return state;
  }
}
