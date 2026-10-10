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
  cursor: null,
  frontier: null,
  hasMore: true,
  loading: false,
  loaded: false,
  error: null,
  partial: false,
  suspended: false,
  retryAt: null,
  filterResults: ImmutableMap(),
});

const initialState = ImmutableMap();

const currentSession = (state, columnKey) => state.getIn([columnKey, 'sessionId']);

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
      definitionFingerprint: action.definitionFingerprint,
      sessionId: action.sessionId,
      running: true,
      metrics: ImmutableMap({ requests: 0, fetched: 0, extraPages: 0 }),
      sources: action.sources.reduce(
        (map, source) => map.set(source.key, initialSource.set('descriptor', fromJS(source.descriptor))),
        ImmutableMap(),
      ),
    }));
  case MIX_TIMELINE_CLOSE:
    return state.delete(action.columnKey);
  case MIX_TIMELINE_DONE:
    if (currentSession(state, action.columnKey) !== action.sessionId || state.getIn([action.columnKey, 'definitionFingerprint']) !== action.definitionFingerprint) {
      return state;
    }

    return state.setIn([action.columnKey, 'running'], false);
  case MIX_SOURCE_REQUEST:
    if (currentSession(state, action.columnKey) !== action.sessionId || state.getIn([action.columnKey, 'definitionFingerprint']) !== action.definitionFingerprint) {
      return state;
    }

    return state
      .setIn([action.columnKey, 'running'], true)
      .setIn([action.columnKey, 'sources', action.sourceKey, 'loading'], true);
  case MIX_SOURCE_SUCCESS:
    if (currentSession(state, action.columnKey) !== action.sessionId || state.getIn([action.columnKey, 'definitionFingerprint']) !== action.definitionFingerprint) {
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
      const results = (source.get('filterResults') || ImmutableMap()).merge(fromJS(action.filterResults || {}));

      return source.merge({
        ids,
        cursor: action.cursor,
        frontier: action.partial ? source.get('frontier') : action.frontier,
        hasMore: action.hasMore,
        loading: false,
        loaded: true,
        error: null,
        partial: !!action.partial,
        suspended: !!action.suspended,
        retryAt: null,
        filterResults: action.clear ? ImmutableMap() : results,
      });
    }).updateIn([action.columnKey, 'metrics'], ImmutableMap(), metrics => metrics.merge({
      requests: metrics.get('requests', 0) + 1,
      fetched: metrics.get('fetched', 0) + action.ids.length,
      extraPages: metrics.get('extraPages', 0) + (action.extra ? 1 : 0),
    }));
  case MIX_SOURCE_FAIL:
    if (currentSession(state, action.columnKey) !== action.sessionId || state.getIn([action.columnKey, 'definitionFingerprint']) !== action.definitionFingerprint) {
      return state;
    }

    return state.updateIn([action.columnKey, 'sources', action.sourceKey], initialSource, source => source.merge({
      ids: action.clear ? ImmutableList() : source.get('ids'),
      filterResults: action.clear ? ImmutableMap() : source.get('filterResults'),
      frontier: action.clear ? null : source.get('frontier'),
      loading: false,
      loaded: true,
      hasMore: action.error === 'forbidden' || action.error === 'not_found' || action.error === 'stalled' || action.error === 'order' ? false : source.get('hasMore'),
      error: action.error,
      suspended: false,
      retryAt: action.retryAt || null,
    })).updateIn([action.columnKey, 'metrics'], ImmutableMap(), metrics => metrics.merge({
      requests: metrics.get('requests', 0) + 1,
    }));
  case ACCOUNT_BLOCK_SUCCESS:
  case ACCOUNT_MUTE_SUCCESS:
    return removeIds(state, idsForRelationship(action.statuses, action.relationship));
  default:
    return state;
  }
}
