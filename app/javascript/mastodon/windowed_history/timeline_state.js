import { List as ImmutableList, fromJS } from 'immutable';

import { HISTORY_EDGE } from './constants';
import {
  applyHistoryPage,
  beginHistoryRequest,
  commitHistoryAnchor,
  edgeIds,
  failHistoryRequest,
  reconcileHasMore,
  reconcileHistoryItems,
  refreshHistoryEdges,
  responseIsCurrent,
  selectInitialWindow,
} from './model';

export const plainItems = (list) => (list && list.toArray ? list.toArray() : []);

export const plainWindow = (windowState) => {
  if (!windowState || !windowState.get) {
    return null;
  }

  const edge = (name) => ({
    status: windowState.getIn([name, 'status']),
    requestId: windowState.getIn([name, 'requestId']) || null,
    cursor: windowState.getIn([name, 'cursor']) || null,
  });

  return {
    generation: windowState.get('generation'),
    revision: windowState.get('revision') || 0,
    anchorId: windowState.get('anchorId') || null,
    anchorResolution: windowState.get('anchorResolution'),
    unbounded: !!windowState.get('unbounded'),
    boundaryId: windowState.get('boundaryId') || null,
    newestId: windowState.get('newestId') || null,
    oldestId: windowState.get('oldestId') || null,
    hasNewer: !!windowState.get('hasNewer'),
    hasOlder: !!windowState.get('hasOlder'),
    newer: edge('newer'),
    older: edge('older'),
  };
};

const statusIds = (statuses) => {
  const list = statuses && statuses.toArray ? statuses.toArray() : (statuses || []);

  return list.map(status => {
    if (!status) {
      return null;
    }

    const id = typeof status.get === 'function' ? status.get('id') : status.id;

    return typeof id === 'string' ? id : null;
  }).filter(id => typeof id === 'string');
};

const writeWindow = (timeline, items, windowState) => {
  const olderStatus = windowState.older.status;
  const awaitingAnchor = !!windowState.unbounded;

  return timeline.withMutations(map => {
    map.set('items', ImmutableList(items));
    map.set('hasMore', !awaitingAnchor && !!windowState.hasOlder && (olderStatus === HISTORY_EDGE.OPEN || olderStatus === HISTORY_EDGE.LOADING));
    map.set('isLoading', olderStatus === HISTORY_EDGE.LOADING);
    map.set('window', fromJS(windowState));
  });
};

export const initialHistoryWindow = (items, anchorId, sourceHasMore) => {
  const list = plainItems(items);
  const boundaryId = edgeIds(list).newestId;

  return selectInitialWindow(list, anchorId, {
    sourceHasMore: !!sourceHasMore,
    boundaryId,
  });
};

export const requestHistory = (timeline, action) => {
  const current = plainWindow(timeline.get('window'));

  if (!current) {
    return timeline;
  }

  const next = beginHistoryRequest(current, action);

  if (!next.accepted) {
    return timeline;
  }

  return writeWindow(timeline, plainItems(timeline.get('items')), next.window);
};

export const succeedHistory = (timeline, action) => {
  const current = plainWindow(timeline.get('window'));

  if (!current || !responseIsCurrent(current, action)) {
    return timeline;
  }

  const pageIds = statusIds(action.statuses);
  const applied = applyHistoryPage(current, plainItems(timeline.get('items')), {
    pageIds,
    direction: action.direction,
    partial: !!action.partial,
    capability: action.capability,
    limit: action.limit,
    anchorId: action.anchorId,
    cursor: action.cursor,
    gap: !!action.gap,
  });

  return writeWindow(timeline, applied.items, applied.window);
};

export const failHistory = (timeline, action) => {
  const current = plainWindow(timeline.get('window'));

  if (!current) {
    return timeline;
  }

  const next = failHistoryRequest(current, action);

  if (next === current) {
    return timeline;
  }

  return writeWindow(timeline, plainItems(timeline.get('items')), next);
};

export const placeHistoryAnchor = (timeline, anchorId) => {
  const current = plainWindow(timeline.get('window'));

  if (!current) {
    return timeline;
  }

  const placed = commitHistoryAnchor(plainItems(timeline.get('items')), current, anchorId, {
    sourceHasMore: current.hasOlder || timeline.get('hasMore'),
  });

  if (!placed || placed.window === current) {
    return timeline;
  }

  return writeWindow(timeline, placed.items, placed.window);
};

export const syncHistoryEdges = (timeline) => {
  const current = plainWindow(timeline.get('window'));

  if (!current) {
    return timeline;
  }

  const items = plainItems(timeline.get('items'));
  const next = refreshHistoryEdges(items, current);

  return timeline.set('window', fromJS(next));
};

export const keptHistoryItems = (sourceItems, historyItems, sourceHasMore, windowState) => {
  const source = plainItems(sourceItems);
  const history = plainItems(historyItems);
  const plain = windowState && windowState.get ? plainWindow(windowState) : windowState;

  return {
    items: reconcileHistoryItems(source, history, plain && plain.boundaryId),
    hasMore: reconcileHasMore(sourceHasMore, source, history, plain),
  };
};

// Legacy expand responses on a windowed history are older pages. A missing
// next link is a short page; a present next link is a full page. Partial
// responses become a gap and do not mark the feed exhausted.
export const succeedExpandedHistory = (timeline, action) => {
  const current = plainWindow(timeline.get('window'));

  if (!current) {
    return null;
  }

  if (action.isLoadingRecent) {
    return timeline.set('isLoading', false);
  }

  const pageIds = statusIds(action.statuses);
  const applied = applyHistoryPage({
    ...current,
    older: {
      ...current.older,
      requestId: action.requestId || current.older.requestId || 'expand',
    },
  }, plainItems(timeline.get('items')), {
    pageIds,
    direction: 'older',
    partial: !!action.partial,
    capability: action.capability || current.capability || 'database',
    limit: action.next ? pageIds.length : pageIds.length + 1,
    cursor: current.oldestId,
    anchorId: current.anchorId,
  });

  return writeWindow(timeline, applied.items, applied.window);
};
