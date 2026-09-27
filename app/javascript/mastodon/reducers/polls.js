import { POLLS_IMPORT } from 'mastodon/actions/importer';
import { Map as ImmutableMap, fromJS } from 'immutable';
import { normalizePollOptionTranslation } from '../actions/importer/normalizer';
import { STATUS_TRANSLATE_FAIL, STATUS_TRANSLATE_REQUEST, STATUS_TRANSLATE_SUCCESS, STATUS_TRANSLATE_UNDO } from '../actions/statuses';

const importPolls = (state, polls) => state.withMutations(map => polls.forEach(poll => map.set(poll.id, fromJS(poll))));

const statusTranslateRequest = (state, pollId, requestId) => {
  if (!pollId || !requestId || !state.get(pollId)) {
    return state;
  }

  return state.setIn([pollId, 'translationRequestId'], requestId);
};

const statusTranslateSuccess = (state, pollTranslation, requestId) => {
  if (!pollTranslation || !state.get(pollTranslation.id)) {
    return state;
  }

  const poll = state.get(pollTranslation.id);

  if (poll.get('translationRequestId') !== requestId) {
    return state;
  }

  return state.withMutations(map => {
    pollTranslation.options.forEach((item, index) => {
      map.setIn([pollTranslation.id, 'options', index, 'translation'], fromJS(normalizePollOptionTranslation(item, poll)));
    });

    map.deleteIn([pollTranslation.id, 'translationRequestId']);
  });
};

const statusTranslateFail = (state, pollId, requestId) => {
  if (!pollId || !state.get(pollId) || state.getIn([pollId, 'translationRequestId']) !== requestId) {
    return state;
  }

  return state.deleteIn([pollId, 'translationRequestId']);
};

const statusTranslateUndo = (state, id) => {
  const options = state.getIn([id, 'options']);

  if (!options) {
    return state;
  }

  return state.withMutations(map => {
    options.forEach((_item, index) => map.deleteIn([id, 'options', index, 'translation']));
    map.deleteIn([id, 'translationRequestId']);
  });
};

const initialState = ImmutableMap();

export default function polls(state = initialState, action) {
  switch(action.type) {
  case POLLS_IMPORT:
    return importPolls(state, action.polls);
  case STATUS_TRANSLATE_REQUEST:
    return statusTranslateRequest(state, action.pollId, action.translationRequestId);
  case STATUS_TRANSLATE_SUCCESS:
    return statusTranslateSuccess(state, action.translation && action.translation.poll, action.translationRequestId);
  case STATUS_TRANSLATE_FAIL:
    return statusTranslateFail(state, action.pollId, action.translationRequestId);
  case STATUS_TRANSLATE_UNDO:
    return statusTranslateUndo(state, action.pollId);
  default:
    return state;
  }
}
