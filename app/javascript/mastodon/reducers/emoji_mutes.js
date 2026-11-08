import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import { EMOJI_MUTES_IMPORT, EMOJI_MUTES_REVISION } from '../actions/emoji_mutes';

const initialState = ImmutableMap({
  revision: null,
  rules: ImmutableList(),
});

const newer = (incoming, current) => {
  if (incoming === null || incoming === undefined || incoming === '') {
    return false;
  }

  if (current === null || current === undefined || current === '') {
    return true;
  }

  const left = String(incoming);
  const right = String(current);

  if (left.length === right.length) {
    return left > right;
  }

  return left.length > right.length;
};

export default function emojiMutes(state = initialState, action) {
  switch (action.type) {
  case EMOJI_MUTES_IMPORT:
    if (state.get('revision') !== null && !newer(action.revision, state.get('revision')) && String(action.revision) !== String(state.get('revision'))) {
      return state;
    }

    return state
      .set('revision', action.revision === null || action.revision === undefined ? state.get('revision') : String(action.revision))
      .set('rules', fromJS(action.rules || []));
  case EMOJI_MUTES_REVISION:
    if (!newer(action.revision, state.get('revision'))) {
      return state;
    }

    return state.set('revision', String(action.revision));
  default:
    return state;
  }
}
