import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import { EMOJI_MUTES_APPLY, EMOJI_MUTES_IMPORT, EMOJI_MUTES_REVISION, EMOJI_MUTES_LOAD, EMOJI_MUTES_FAIL, EMOJI_MUTES_RESET } from '../actions/emoji_mutes';

// revision is the newest *observed* revision; appliedRevision is the version
// whose complete rules are in Redux. Never render an observed revision using
// rules from an older applied document.
const initialState = ImmutableMap({
  revision: null,
  appliedRevision: null,
  phase: 'loading',
  rules: ImmutableList(),
});

const REVISION = /^(?:0|[1-9]\d*)$/;

const validRevision = value => value !== null && value !== undefined && REVISION.test(String(value));

const newer = (incoming, current) => {
  if (!validRevision(incoming)) {
    return false;
  }

  if (!validRevision(current)) {
    return true;
  }

  const left = String(incoming);
  const right = String(current);

  return left.length > right.length || (left.length === right.length && left > right);
};

const older = (incoming, current) => newer(current, incoming);

const applyDocument = (state, action, items) => {
  if (!validRevision(action.revision)) {
    // Old call sites without a document revision can update rules for
    // compatibility, but cannot mark the display ready.
    return state.get('revision') === null ? state.set('rules', fromJS(items || [])) : state;
  }

  const incoming = String(action.revision);
  const observed = state.get('revision');
  const applied = state.get('appliedRevision');

  if (older(incoming, observed) || older(incoming, applied)) {
    return state;
  }

  return state
    .set('revision', newer(incoming, observed) ? incoming : observed || incoming)
    .set('appliedRevision', incoming)
    .set('rules', fromJS(items || []))
    .set('phase', 'ready');
};

export default function emojiMutes(state = initialState, action) {
  switch (action.type) {
  case EMOJI_MUTES_RESET:
    return initialState;
  case EMOJI_MUTES_LOAD:
    // Revalidation of an already current document need not hide the UI.
    return state.get('appliedRevision') === null || older(state.get('appliedRevision'), state.get('revision'))
      ? state.set('phase', 'loading')
      : state;
  case EMOJI_MUTES_FAIL:
    return state.set('phase', 'error');
  case EMOJI_MUTES_IMPORT:
    return applyDocument(state, action, action.rules);
  case EMOJI_MUTES_APPLY:
    return applyDocument(state, action, action.mutes);
  case EMOJI_MUTES_REVISION:
    if (!newer(action.revision, state.get('revision'))) {
      return state;
    }

    return state
      .set('revision', String(action.revision))
      .set('phase', 'stale');
  default:
    return state;
  }
}
