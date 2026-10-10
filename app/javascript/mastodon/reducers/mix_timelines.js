import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import compareId from '../compare_id';
import { STORE_HYDRATE } from '../actions/store';
import { ACCOUNT_BLOCK_SUCCESS, ACCOUNT_MUTE_SUCCESS } from '../actions/accounts';
import { MIX_REREAD_LIMIT, MIX_TOMBSTONE_LIMIT } from '../mix/merge';
import {
  MIX_TIMELINE_OPEN,
  MIX_TIMELINE_CLOSE,
  MIX_TIMELINE_DONE,
  MIX_SOURCE_REQUEST,
  MIX_SOURCE_SUCCESS,
  MIX_SOURCE_FAIL,
  MIX_STREAM_READY,
  MIX_STREAM_CONNECT,
  MIX_STREAM_DISCONNECT,
  MIX_STREAM_STATUS,
  MIX_STREAM_EDIT,
  MIX_STREAM_REMOVE,
  MIX_STREAM_SYNC,
  MIX_STREAM_PIN,
  MIX_STREAM_REVEAL,
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
  gap: false,
  reread: false,
  rereads: 0,
  retryAt: null,
  filterResults: ImmutableMap(),
});

const initialLive = ImmutableMap({
  statusIds: ImmutableList(),
  filterResults: ImmutableMap(),
  connected: false,
  disconnectedAt: null,
  syncState: 'idle',
  lastReceivedId: null,
  lastReconciledId: null,
  retryAt: null,
  mode: 'rest_only',
  channels: ImmutableMap(),
});

const initialState = ImmutableMap();

const newerId = (left, right) => {
  if (!left) {
    return right || null;
  }

  if (!right) {
    return left;
  }

  return compareId(left, right) >= 0 ? left : right;
};

const withoutIds = (list, blocked) => (list || ImmutableList()).filter(id => !blocked.has(id));

const rememberTombstones = (existing, ids) => {
  const next = (existing || ImmutableList()).concat(ids.filter(id => !existing || !existing.includes(id)));

  if (next.size <= MIX_TOMBSTONE_LIMIT) {
    return next;
  }

  return next.slice(next.size - MIX_TOMBSTONE_LIMIT);
};

const currentSession = (state, columnKey) => state.getIn([columnKey, 'sessionId']);

const appendIds = (source, incoming) => {
  const seen = new Set(source.get('ids').toArray());

  return source.get('ids').withMutations(list => {
    (incoming || []).forEach(id => {
      if (!seen.has(id)) {
        seen.add(id);
        list.push(id);
      }
    });
  });
};

// A 200 that continues after 206 only shows that rebuilding has stopped.
// The rows already fetched can still be missing, so the source is reread
// once from the head. Another 206 keeps the source incomplete.
const settlePage = (source, action) => {
  const pagePartial = !!action.partial;
  const fromHead = !action.requestedCursor;
  const gap = !!source.get('gap');
  const rereads = source.get('rereads') || 0;
  const replace = fromHead && !pagePartial && (gap || source.get('reread'));
  const ids = replace ? ImmutableList(action.ids || []) : appendIds(source, action.ids);
  const stored = source.get('filterResults') || ImmutableMap();
  const filterResults = action.clear ? ImmutableMap() : stored.merge(fromJS(action.filterResults || {}));
  const base = {
    ids,
    loading: false,
    loaded: true,
    error: null,
    retryAt: null,
    filterResults,
  };

  if (pagePartial) {
    const rereadStillPartial = fromHead && (gap || source.get('reread'));

    return source.merge({
      ...base,
      cursor: rereadStillPartial ? null : action.cursor,
      frontier: null,
      hasMore: true,
      partial: true,
      suspended: rereadStillPartial ? true : !!action.suspended,
      gap: true,
      reread: false,
      rereads,
    });
  }

  if (gap && !fromHead) {
    if (rereads >= MIX_REREAD_LIMIT) {
      return source.merge({
        ...base,
        cursor: null,
        frontier: null,
        hasMore: true,
        partial: true,
        suspended: true,
        gap: true,
        reread: false,
        rereads,
      });
    }

    return source.merge({
      ...base,
      cursor: null,
      frontier: null,
      hasMore: true,
      partial: true,
      suspended: false,
      gap: true,
      reread: true,
      rereads: rereads + 1,
    });
  }

  return source.merge({
    ...base,
    cursor: action.cursor,
    frontier: action.frontier,
    hasMore: action.hasMore,
    partial: false,
    suspended: false,
    gap: false,
    reread: false,
    rereads: 0,
  });
};

const removeIds = (state, ids) => {
  if (!ids || !ids.length) {
    return state;
  }

  const blocked = new Set(ids);

  return state.map(timeline => timeline
    .update('sources', sources => sources.map(source => source.update('ids', list => list.filter(id => !blocked.has(id)))))
    .update('live', live => (live || ImmutableMap()).map(entry => entry.update('statusIds', list => withoutIds(list, blocked))))
    .update('pendingStatusIds', list => withoutIds(list, blocked)));
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
      live: ImmutableMap(),
      pendingStatusIds: ImmutableList(),
      deletedStatusIds: ImmutableList(),
      pinnedToTop: true,
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

    const blocked = new Set((state.getIn([action.columnKey, 'deletedStatusIds']) || ImmutableList()).toArray());
    const visibleIds = (action.ids || []).filter(id => !blocked.has(id));

    return state.updateIn([action.columnKey, 'sources', action.sourceKey], initialSource, source => {
      return settlePage(source, { ...action, ids: visibleIds });
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
  case MIX_STREAM_READY:
    if (!sameSession(state, action)) {
      return state;
    }

    return state.updateIn([action.columnKey, 'live'], ImmutableMap(), live => (action.sources || []).reduce((map, source) => {
      const channels = (source.channels || []).reduce((states, channelId) => states.set(channelId, 'idle'), ImmutableMap());

      return map.update(source.key, initialLive, entry => entry.merge({
        mode: source.mode,
        channels,
      }));
    }, live));
  case MIX_STREAM_CONNECT:
  case MIX_STREAM_DISCONNECT:
  case MIX_STREAM_SYNC:
    if (!sameSession(state, action)) {
      return state;
    }

    return state.updateIn([action.columnKey, 'live', action.sourceKey], initialLive, entry => {
      let channels = entry.get('channels') || ImmutableMap();

      if (action.channelId) {
        channels = channels.set(action.channelId, action.type === MIX_STREAM_DISCONNECT ? 'disconnected' : 'connected');
      }

      const channelStates = channels.valueSeq().toArray();
      let connected = entry.get('connected');
      let syncState = action.syncState;

      if (channelStates.length) {
        connected = channelStates.every(item => item === 'connected');
        if (channelStates.some(item => item === 'disconnected')) {
          syncState = syncState || 'disconnected';
        } else if (connected) {
          syncState = syncState || 'connected';
        } else {
          syncState = syncState || 'idle';
        }
      } else if (action.type === MIX_STREAM_CONNECT) {
        connected = true;
        syncState = syncState || 'connected';
      } else if (action.type === MIX_STREAM_DISCONNECT) {
        connected = false;
        syncState = syncState || 'disconnected';
      }

      return entry.merge({
        channels,
        connected,
        disconnectedAt: action.type === MIX_STREAM_DISCONNECT ? (action.disconnectedAt || Date.now()) : entry.get('disconnectedAt'),
        syncState: syncState || entry.get('syncState'),
        lastReconciledId: action.lastReconciledId === undefined ? entry.get('lastReconciledId') : action.lastReconciledId,
        retryAt: action.retryAt === undefined ? entry.get('retryAt') : action.retryAt,
      });
    });
  case MIX_STREAM_STATUS:
    if (!sameSession(state, action) || !action.id) {
      return state;
    }

    if ((state.getIn([action.columnKey, 'deletedStatusIds']) || ImmutableList()).includes(action.id)) {
      return state;
    }

    if (action.decision === 'reject' || action.decision === 'unknown') {
      return state.updateIn([action.columnKey, 'live', action.sourceKey], initialLive, entry => entry.update('statusIds', list => list.filter(id => id !== action.id)));
    }

    return state.updateIn([action.columnKey, 'live', action.sourceKey], initialLive, entry => {
      const ids = entry.get('statusIds').includes(action.id) ? entry.get('statusIds') : entry.get('statusIds').push(action.id);
      const results = entry.get('filterResults').merge(fromJS({ [action.id]: action.filterResults || [] }));

      return entry.merge({
        statusIds: ids,
        filterResults: results,
        lastReceivedId: newerId(entry.get('lastReceivedId'), action.id),
      });
    }).updateIn([action.columnKey, 'pendingStatusIds'], ImmutableList(), pending => {
      if (state.getIn([action.columnKey, 'pinnedToTop']) || pending.includes(action.id)) {
        return pending;
      }

      return pending.push(action.id);
    });
  case MIX_STREAM_EDIT:
    if (!sameSession(state, action) || !action.id) {
      return state;
    }

    return (action.decisions || []).reduce((next, decision) => {
      const resultsFor = (entry) => entry.get('filterResults').merge(fromJS({ [action.id]: decision.filterResults || [] }));

      if (decision.decision === 'reject') {
        return next
          .updateIn([action.columnKey, 'live', decision.sourceKey], initialLive, entry => entry.merge({
            statusIds: entry.get('statusIds').filter(id => id !== action.id),
            filterResults: resultsFor(entry),
          }))
          .updateIn([action.columnKey, 'sources', decision.sourceKey, 'ids'], ImmutableList(), ids => ids.filter(id => id !== action.id))
          .updateIn([action.columnKey, 'pendingStatusIds'], ImmutableList(), ids => ids.filter(id => id !== action.id));
      }

      if (decision.decision === 'accept' && decision.delivered) {
        return next.updateIn([action.columnKey, 'live', decision.sourceKey], initialLive, entry => {
          const ids = entry.get('statusIds').includes(action.id) ? entry.get('statusIds') : entry.get('statusIds').push(action.id);

          return entry.merge({ statusIds: ids, filterResults: resultsFor(entry) });
        });
      }

      if (decision.decision === 'accept') {
        return next.updateIn([action.columnKey, 'live', decision.sourceKey], initialLive, entry => entry.merge({
          filterResults: resultsFor(entry),
        }));
      }

      return next;
    }, state);
  case MIX_STREAM_REMOVE: {
    if (!sameSession(state, action)) {
      return state;
    }

    const removed = [action.id].concat(action.references || []).concat(action.quotes || []).filter(Boolean);

    return removeIds(state, removed).map(timeline => timeline.update('deletedStatusIds', ImmutableList(), existing => rememberTombstones(existing, removed)));
  }
  case MIX_STREAM_PIN:
    if (!sameSession(state, action)) {
      return state;
    }

    return state.setIn([action.columnKey, 'pinnedToTop'], action.pinned !== false).updateIn([action.columnKey, 'pendingStatusIds'], ImmutableList(), pending => (action.pinned === false ? pending : ImmutableList()));
  case MIX_STREAM_REVEAL:
    if (!sameSession(state, action)) {
      return state;
    }

    return state.setIn([action.columnKey, 'pendingStatusIds'], ImmutableList());
  case ACCOUNT_BLOCK_SUCCESS:
  case ACCOUNT_MUTE_SUCCESS:
    return removeIds(state, idsForRelationship(action.statuses, action.relationship));
  default:
    return state;
  }
}

const sameSession = (state, action) => {
  return currentSession(state, action.columnKey) === action.sessionId && state.getIn([action.columnKey, 'definitionFingerprint']) === action.definitionFingerprint;
};
