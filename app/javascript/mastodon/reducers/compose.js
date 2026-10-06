import { STORE_HYDRATE } from '../actions/store';
import { PRIMARY_COMPOSER_ID } from '../utils/composer';
import composer, {
  hydrateComposer,
  initialState,
} from './composer';

export default function compose(state = initialState, action) {
  if (action.type === STORE_HYDRATE) {
    return hydrateComposer(state, action.state.get('compose'));
  }

  const composerId = action.meta?.composerId;

  if (
    composerId !== undefined &&
    composerId !== PRIMARY_COMPOSER_ID
  ) {
    return state;
  }

  return composer(state, action);
}
