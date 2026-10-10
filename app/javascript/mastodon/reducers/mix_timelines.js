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
  MIX_SPLIT_CREATE,
  MIX_SPLIT_DESTROY,
  MIX_SPLIT_ANCHOR,
  MIX_SPLIT_CLEAR_ANCHOR,
  MIX_DISPLAY_HISTORY,
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
  revokedIds: ImmutableList(),
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
const ANCHORS = '__anchors';

const isColumn = (timeline) => !!(timeline && timeline.get && timeline.get('sources'));

const mapColumns = (state, updater) => {
  let next = state;

  state.forEach((timeline, key) => {
    if (key === ANCHORS || !isColumn(timeline)) {
      return;
    }

    next = next.set(key, updater(timeline));
  });

  return next;
};

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
  const revoked = new Set((source.get('revokedIds') || ImmutableList()).toArray());
  const incoming = (action.ids || []).filter(id => !revoked.has(id));
  const ids = replace ? ImmutableList(incoming) : appendIds(source, incoming);
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

  return mapColumns(state, timeline => {
    let next = timeline
      .update('sources', sources => sources.map(source => source.update('ids', list => list.filter(id => !blocked.has(id)))))
      .update('live', live => (live || ImmutableMap()).map(entry => entry.update('statusIds', list => withoutIds(list, blocked))))
      .update('pendingStatusIds', list => withoutIds(list, blocked));

    if (!next.get('split')) {
      return next;
    }

    return next
      .updateIn(['split', 'history', 'sources'], sources => (sources || ImmutableMap()).map(source => source.update('ids', list => list.filter(id => !blocked.has(id)))))
      .updateIn(['split', 'history', 'frozenLive'], live => (live || ImmutableMap()).map(entry => entry.update('ids', list => withoutIds(list, blocked))));
  });
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
    if (action.scope === 'history') {
      if (!historyOpen(state, action)) {
        return state;
      }

      return state.setIn([action.columnKey, 'split', 'history', 'running'], false);
    }

    if (currentSession(state, action.columnKey) !== action.sessionId || state.getIn([action.columnKey, 'definitionFingerprint']) !== action.definitionFingerprint) {
      return state;
    }

    return state.setIn([action.columnKey, 'running'], false);
  case MIX_SOURCE_REQUEST:
    if (action.scope === 'history') {
      if (!historyOpen(state, action)) {
        return state;
      }

      return state
        .setIn([action.columnKey, 'split', 'history', 'running'], true)
        .setIn([action.columnKey, 'split', 'history', 'sources', action.sourceKey, 'loading'], true);
    }

    if (currentSession(state, action.columnKey) !== action.sessionId || state.getIn([action.columnKey, 'definitionFingerprint']) !== action.definitionFingerprint) {
      return state;
    }

    return state
      .setIn([action.columnKey, 'running'], true)
      .setIn([action.columnKey, 'sources', action.sourceKey, 'loading'], true);
  case MIX_SOURCE_SUCCESS:
    if (action.scope === 'history') {
      if (!historyOpen(state, action)) {
        return state;
      }

      const blockedHistory = new Set((state.getIn([action.columnKey, 'deletedStatusIds']) || ImmutableList()).toArray());
      const historyIds = (action.ids || []).filter(id => !blockedHistory.has(id));

      return state.updateIn([action.columnKey, 'split', 'history', 'sources', action.sourceKey], initialSource, source => {
        return settlePage(source, { ...action, ids: historyIds });
      });
    }

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
    if (action.scope === 'history') {
      if (!historyOpen(state, action)) {
        return state;
      }

      return state.updateIn([action.columnKey, 'split', 'history', 'sources', action.sourceKey], initialSource, source => source.merge({
        ids: action.clear ? ImmutableList() : source.get('ids'),
        filterResults: action.clear ? ImmutableMap() : source.get('filterResults'),
        frontier: action.clear ? null : source.get('frontier'),
        loading: false,
        loaded: true,
        hasMore: action.error === 'forbidden' || action.error === 'not_found' || action.error === 'stalled' || action.error === 'order' ? false : source.get('hasMore'),
        error: action.error,
        suspended: false,
        retryAt: action.retryAt || null,
      }));
    }

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
    }).updateIn([action.columnKey, 'sources', action.sourceKey, 'revokedIds'], ImmutableList(), ids => ids.filter(id => id !== action.id)).updateIn([action.columnKey, 'pendingStatusIds'], ImmutableList(), pending => {
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
      const mergeResults = (results) => {
        if (decision.filterResults === null || decision.filterResults === undefined) {
          return results || ImmutableMap();
        }

        return (results || ImmutableMap()).merge(fromJS({ [action.id]: decision.filterResults }));
      };

      if (decision.decision === 'reject') {
        const removed = next
          .updateIn([action.columnKey, 'live', decision.sourceKey], initialLive, entry => entry.merge({
            statusIds: entry.get('statusIds').filter(id => id !== action.id),
            filterResults: mergeResults(entry.get('filterResults')),
          }))
          .updateIn([action.columnKey, 'sources', decision.sourceKey], initialSource, source => source.merge({
            ids: source.get('ids').filter(id => id !== action.id),
            filterResults: mergeResults(source.get('filterResults')),
            revokedIds: rememberTombstones(source.get('revokedIds'), [action.id]),
          }))
          .updateIn([action.columnKey, 'pendingStatusIds'], ImmutableList(), ids => ids.filter(id => id !== action.id));
        const historyPath = [action.columnKey, 'split', 'history', 'sources', decision.sourceKey];

        if (!removed.getIn(historyPath)) {
          return removed;
        }

        const withoutHistory = removed
          .updateIn(historyPath, source => source.merge({
            ids: source.get('ids').filter(id => id !== action.id),
            filterResults: mergeResults(source.get('filterResults')),
            revokedIds: rememberTombstones(source.get('revokedIds'), [action.id]),
          }));
        const frozenPath = [action.columnKey, 'split', 'history', 'frozenLive', decision.sourceKey];

        if (!withoutHistory.getIn(frozenPath)) {
          return withoutHistory;
        }

        return withoutHistory.updateIn(frozenPath, entry => entry.merge({
          ids: (entry.get('ids') || ImmutableList()).filter(id => id !== action.id),
          filterResults: mergeResults(entry.get('filterResults')),
        }));
      }

      if (decision.decision === 'accept' && decision.delivered) {
        return next
          .updateIn([action.columnKey, 'live', decision.sourceKey], initialLive, entry => {
            const ids = entry.get('statusIds').includes(action.id) ? entry.get('statusIds') : entry.get('statusIds').push(action.id);

            return entry.merge({ statusIds: ids, filterResults: mergeResults(entry.get('filterResults')) });
          })
          .updateIn([action.columnKey, 'sources', decision.sourceKey, 'revokedIds'], ImmutableList(), ids => ids.filter(id => id !== action.id));
      }

      if (decision.decision === 'accept') {
        const updated = next
          .updateIn([action.columnKey, 'live', decision.sourceKey], initialLive, entry => entry.merge({
            filterResults: mergeResults(entry.get('filterResults')),
          }))
          .updateIn([action.columnKey, 'sources', decision.sourceKey, 'filterResults'], ImmutableMap(), results => mergeResults(results));
        const historyResults = [action.columnKey, 'split', 'history', 'sources', decision.sourceKey, 'filterResults'];

        if (!updated.getIn([action.columnKey, 'split', 'history', 'sources', decision.sourceKey])) {
          return updated;
        }

        let withHistory = updated.updateIn(historyResults, ImmutableMap(), results => mergeResults(results));
        const frozenResults = [action.columnKey, 'split', 'history', 'frozenLive', decision.sourceKey];

        if (!withHistory.getIn(frozenResults)) {
          return withHistory;
        }

        return withHistory.updateIn(frozenResults.concat(['filterResults']), ImmutableMap(), results => mergeResults(results));
      }

      return next;
    }, state);
  case MIX_STREAM_REMOVE: {
    if (!sameSession(state, action)) {
      return state;
    }

    const removed = [action.id].concat(action.references || []).concat(action.quotes || []).filter(Boolean);

    return mapColumns(removeIds(state, removed), timeline => timeline.update('deletedStatusIds', ImmutableList(), existing => rememberTombstones(existing, removed)));
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
  case MIX_SPLIT_CREATE: {
    if (!sameSession(state, action) || state.getIn([action.columnKey, 'split', 'id'])) {
      return state;
    }

    const openSources = state.getIn([action.columnKey, 'sources']);
    const initialLoad = openSources && openSources.some(source => !source.get('loaded') && !source.get('error'));

    if (initialLoad) {
      return state;
    }

    return state.setIn([action.columnKey, 'split'], ImmutableMap({
      id: action.splitId,
      boundaryId: action.boundaryId || null,
      createdAt: Date.now(),
      returnAnchor: null,
      history: ImmutableMap({
        sources: state.getIn([action.columnKey, 'sources']),
        frozenLive: fromJS(action.frozenLive || {}),
        running: false,
      }),
    }));
  }
  case MIX_SPLIT_DESTROY: {
    if (!sameSession(state, action) || state.getIn([action.columnKey, 'split', 'id']) !== action.splitId) {
      return state;
    }

    if (action.keep === 'live') {
      return state
        .deleteIn([action.columnKey, 'split'])
        .setIn([action.columnKey, 'displayMode'], 'live')
        .setIn([action.columnKey, 'pinnedToTop'], !!action.liveAtTop)
        .setIn([action.columnKey, 'pendingStatusIds'], ImmutableList());
    }

    const historySources = state.getIn([action.columnKey, 'split', 'history', 'sources']);
    const frozen = state.getIn([action.columnKey, 'split', 'history', 'frozenLive']) || ImmutableMap();
    const kept = new Set();

    historySources.forEach(source => source.get('ids').forEach(id => kept.add(id)));
    frozen.forEach(entry => (entry.get('ids') || ImmutableList()).forEach(id => kept.add(id)));

    const pendingIds = [];
    const seenPending = new Set();

    (state.getIn([action.columnKey, 'live']) || ImmutableMap()).forEach(entry => {
      (entry.get('statusIds') || ImmutableList()).forEach(id => {
        if (!kept.has(id) && !seenPending.has(id)) {
          seenPending.add(id);
          pendingIds.push(id);
        }
      });
    });

    return state
      .setIn([action.columnKey, 'sources'], historySources)
      .setIn([action.columnKey, 'pendingStatusIds'], ImmutableList(pendingIds))
      .setIn([action.columnKey, 'displayMode'], null)
      .setIn([action.columnKey, 'pinnedToTop'], pendingIds.length === 0 && action.historyAtTop === true)
      .deleteIn([action.columnKey, 'split']);
  }
  case MIX_SPLIT_ANCHOR:
    if (!action.columnKey || !action.anchor) {
      return state;
    }

    return state.setIn([ANCHORS, action.columnKey], fromJS(action.anchor));
  case MIX_SPLIT_CLEAR_ANCHOR:
    if (!action.columnKey) {
      return state;
    }

    return state.deleteIn([ANCHORS, action.columnKey]);
  case MIX_DISPLAY_HISTORY:
    if (!sameSession(state, action)) {
      return state;
    }

    return state.setIn([action.columnKey, 'displayMode'], null);
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

const historyOpen = (state, action) => {
  return action.scope === 'history' && state.getIn([action.columnKey, 'split', 'id']) === action.splitId && sameSession(state, action);
};
