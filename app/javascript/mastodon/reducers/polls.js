import { POLLS_IMPORT } from 'mastodon/actions/importer';
import { Map as ImmutableMap, fromJS } from 'immutable';
import { normalizePollOptionTranslation } from '../actions/importer/normalizer';
import { STATUS_TRANSLATE_SUCCESS, STATUS_TRANSLATE_UNDO } from '../actions/statuses';

const importPolls = (state, polls) => state.withMutations(map => polls.forEach(poll => map.set(poll.id, fromJS(poll))));

const statusTranslateSuccess = (state, pollTranslation) => {
  if (!pollTranslation || !state.get(pollTranslation.id)) {
    return state;
  }

  const poll = state.get(pollTranslation.id);

  return state.withMutations(map => {
    pollTranslation.options.forEach((item, index) => {
      map.setIn([pollTranslation.id, 'options', index, 'translation'], fromJS(normalizePollOptionTranslation(item, poll)));
    });
  });
};

const statusTranslateUndo = (state, id) => {
  const options = state.getIn([id, 'options']);

  if (!options) {
    return state;
  }

  return state.withMutations(map => {
    options.forEach((_item, index) => map.deleteIn([id, 'options', index, 'translation']));
  });
};

const initialState = ImmutableMap();

export default function polls(state = initialState, action) {
  switch(action.type) {
  case POLLS_IMPORT:
    return importPolls(state, action.polls);
  case STATUS_TRANSLATE_SUCCESS:
    return statusTranslateSuccess(state, action.translation && action.translation.poll);
  case STATUS_TRANSLATE_UNDO:
    return statusTranslateUndo(state, action.pollId);
  default:
    return state;
  }
}
