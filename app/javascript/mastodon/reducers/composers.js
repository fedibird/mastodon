import { Map as ImmutableMap, fromJS } from 'immutable';
import { COMPOSER_CREATE, COMPOSER_DESTROY } from '../actions/composer';
import { POSTING_IDENTITIES_FETCH_FAIL, POSTING_IDENTITIES_FETCH_SUCCESS } from '../actions/posting_identities';
import { TIMELINE_DELETE, TIMELINE_EXPIRE } from '../actions/timelines';
import { PRIMARY_COMPOSER_ID } from '../utils/composer';
import composer, { hydrateComposer, initialState as initialComposerState } from './composer';

const initialState = ImmutableMap({
  byId: ImmutableMap(),
});

const isValidPortableComposerId = composerId => (
  typeof composerId === 'string' &&
  composerId !== '' &&
  composerId !== PRIMARY_COMPOSER_ID
);

export default function composers(state = initialState, action) {
  const composerId = action.meta?.composerId;

  switch(action.type) {
  case COMPOSER_CREATE: {
    if (!isValidPortableComposerId(composerId) || state.hasIn(['byId', composerId])) {
      return state;
    }

    const composerState = action.seed
      ? hydrateComposer(
        initialComposerState,
        ImmutableMap.isMap(action.seed) ? action.seed : fromJS(action.seed),
      )
      : initialComposerState;

    return state.setIn(['byId', composerId], composerState);
  }
  case COMPOSER_DESTROY:
    if (!isValidPortableComposerId(composerId) || !state.hasIn(['byId', composerId])) {
      return state;
    }

    return state.deleteIn(['byId', composerId]);
  case TIMELINE_DELETE:
  case TIMELINE_EXPIRE:
    return state.update('byId', byId => byId.map(instance => composer(instance, action)));
  case POSTING_IDENTITIES_FETCH_SUCCESS:
  case POSTING_IDENTITIES_FETCH_FAIL:
    if (!action.meta || !action.meta.composerId) {
      return state.update('byId', byId => byId.map(instance => composer(instance, action)));
    }

    break;
  default:
    break;
  }

  if (!isValidPortableComposerId(composerId) || !state.hasIn(['byId', composerId])) {
    return state;
  }

  return state.updateIn(
    ['byId', composerId],
    composerState => composer(composerState, action),
  );
}
