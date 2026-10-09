import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import { STORE_HYDRATE } from '../actions/store';
import { ACCOUNT_BLOCK_SUCCESS, ACCOUNT_MUTE_SUCCESS } from '../actions/accounts';
import {
  MIX_TIMELINE_OPEN,
  MIX_TIMELINE_CLOSE,
  MIX_TIMELINE_DONE,
  MIX_SOURCE_REQUEST,
  MIX_SOURCE_SUCCESS,
  MIX_SOURCE_FAIL,
} from '../actions/mix_timelines';

const initialSource = ImmutableMap({
  ids: ImmutableList(),
  next: null,
  hasMore: true,
  loading: false,
  loaded: false,
  error: null,
});

const initialState = ImmutableMap();

const currentGeneration = (state, columnKey) => state.getIn([columnKey, 'generation']);

const removeIds = (state, ids) => {
  if (!ids || !ids.length) {
    return state;
  }

  const blocked = new Set(ids);

  return state.map(timeline => timeline.update('sources', sources => sources.map(source => source.update('ids', list => list.filter(id => !blocked.has(id))))));
};

const idsForRelationship = (statuses, relationship) => {
  if (!statuses || !relationship) {
    return [];
  }

  const accountId = relationship.id || relationship.get && relationship.get('id');
  const removed = [];

  statuses.forEach(status => {
    if (!status || !status.get) {
      return;
    }

    if (status.get('account') === accountId) {
      removed.push(status.get('id'));
    }
  });

  statuses.forEach(status => {
    if (status && status.get && removed.indexOf(status.get('reblog')) !== -1) {
      removed.push(status.get('id'));
    }
  });

  return removed;
};

export default function mixTimelines(state = initialState, action) {
  switch (action.type) {
  case STORE_HYDRATE:
    return initialState;
  case MIX_TIMELINE_OPEN:
    return state.set(action.columnKey, ImmutableMap({
      mixId: action.mixId,
      signature: action.signature,
      generation: action.generation,
      running: true,
      sources: action.sources.reduce(
        (map, source) => map.set(source.key, initialSource.set('descriptor', fromJS(source.descriptor))),
        ImmutableMap(),
      ),
    }));
  case MIX_TIMELINE_CLOSE:
    return state.delete(action.columnKey);
  case MIX_TIMELINE_DONE:
    if (currentGeneration(state, action.columnKey) !== action.generation) {
      return state;
    }

    return state.setIn([action.columnKey, 'running'], false);
  case MIX_SOURCE_REQUEST:
    if (currentGeneration(state, action.columnKey) !== action.generation) {
      return state;
    }

    return state
      .setIn([action.columnKey, 'running'], true)
      .setIn([action.columnKey, 'sources', action.sourceKey, 'loading'], true);
  case MIX_SOURCE_SUCCESS:
    if (currentGeneration(state, action.columnKey) !== action.generation) {
      return state;
    }

    return state.updateIn([action.columnKey, 'sources', action.sourceKey], initialSource, source => {
      const seen = new Set(source.get('ids').toArray());
      const ids = source.get('ids').withMutations(list => {
        action.ids.forEach(id => {
          if (!seen.has(id)) {
            seen.add(id);
            list.push(id);
          }
        });
      });

      return source.merge({
        ids,
        next: action.next,
        hasMore: action.hasMore,
        loading: false,
        loaded: true,
        error: null,
      });
    });
  case MIX_SOURCE_FAIL:
    if (currentGeneration(state, action.columnKey) !== action.generation) {
      return state;
    }

    return state.updateIn([action.columnKey, 'sources', action.sourceKey], initialSource, source => source.merge({
      ids: action.clear ? ImmutableList() : source.get('ids'),
      loading: false,
      loaded: true,
      hasMore: action.error === 'forbidden' || action.error === 'not_found' ? false : source.get('hasMore'),
      error: action.error,
    }));
  case ACCOUNT_BLOCK_SUCCESS:
  case ACCOUNT_MUTE_SUCCESS:
    return removeIds(state, idsForRelationship(action.statuses, action.relationship));
  default:
    return state;
  }
}
