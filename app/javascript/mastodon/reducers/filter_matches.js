import { Map as ImmutableMap, OrderedMap, List, is } from 'immutable';
import { FILTERS_FETCH_SUCCESS } from '../actions/filters';
import { FILTER_MATCHES_REQUEST, FILTER_MATCHES_SUCCESS, FILTER_MATCHES_FAIL, FILTER_MATCHES_CLEAR } from '../actions/filter_matches';
import { filterRules } from '../utils/filter_rules';

export const FILTER_MATCHES_LIMIT = 2000;

const initialState = ImmutableMap({ baseline: false, generation: 0, serial: 0, needsReconcile: false, rules: ImmutableMap(), entries: OrderedMap() });

export default function filterMatches(state = initialState, action) {
  switch (action.type) {
  case FILTERS_FETCH_SUCCESS: {
    const rules = filterRules(action.filters);
    const changed = state.get('baseline') && !is(state.get('rules'), rules);
    return state.merge({ baseline: true, rules, generation: state.get('generation') + (changed ? 1 : 0), needsReconcile: state.get('needsReconcile') || changed });
  }
  case FILTER_MATCHES_CLEAR:
    return state.update('entries', entries => action.ids ? entries.withMutations(map => action.ids.forEach(id => map.delete(id))) : OrderedMap());
  case FILTER_MATCHES_REQUEST: {
    if (action.generation !== state.get('generation')) return state;
    let entries = state.get('entries');
    action.ids.forEach(id => {
      const entry = entries.get(id, ImmutableMap());
      entries = entries.delete(id).set(id, entry.merge({ phase: 'pending', requestId: action.requestId, generation: action.generation }));
    });
    while (entries.size > FILTER_MATCHES_LIMIT) entries = entries.delete(entries.keySeq().first());
    return state.merge({ serial: action.requestId, entries });
  }
  case FILTER_MATCHES_SUCCESS:
  case FILTER_MATCHES_FAIL:
    if (action.generation !== state.get('generation')) return state;
    return state.update('entries', entries => entries.withMutations(map => {
      action.ids.forEach(id => {
        const entry = map.get(id);
        if (!entry || entry.get('requestId') !== action.requestId || entry.get('generation') !== action.generation) return;
        if (action.type === FILTER_MATCHES_FAIL) {
          map.set(id, entry.set('phase', 'failed'));
        } else if (Object.prototype.hasOwnProperty.call(action.matches, id)) {
          map.set(id, entry.merge({ phase: 'ready', resultGeneration: action.generation, filterIds: List(Array.from(new Set(action.matches[id]))) }));
        } else {
          map.set(id, entry.set('phase', 'unavailable').delete('filterIds').delete('resultGeneration'));
        }
      });
    }));
  default:
    return state;
  }
}
