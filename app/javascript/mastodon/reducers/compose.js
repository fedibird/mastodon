import { STORE_HYDRATE } from '../actions/store';
import composer, {
  hydrateComposer,
  initialState,
} from './composer';

export default function compose(state = initialState, action) {
  if (action.type === STORE_HYDRATE) {
    return hydrateComposer(state, action.state.get('compose'));
  }

  return composer(state, action);
}
