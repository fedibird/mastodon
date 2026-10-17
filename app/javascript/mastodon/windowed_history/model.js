import compareId from '../compare_id';
import {
  HISTORY_CAPABILITY,
  HISTORY_EDGE,
  WINDOW_HARD_CAP,
  WINDOW_PAGE_LIMIT,
  WINDOW_TARGET,
} from './constants';

const isReal = (id) => typeof id === 'string' && id.length > 0;

const edgeState = (status, cursor = null) => ({
  status,
  requestId: null,
  cursor,
});

const findLastIndex = (list, predicate) => {
  for (let index = list.length - 1; index >= 0; index -= 1) {
    if (predicate(list[index], index)) {
      return index;
    }
  }

  return -1;
};

export const realCount = (items) => (items || []).reduce((count, id) => count + (isReal(id) ? 1 : 0), 0);

export const edgeIds = (items) => {
  let newestId = null;
  let oldestId = null;

  (items || []).forEach(id => {
    if (!isReal(id)) {
      return;
    }

    if (newestId === null) {
      newestId = id;
    }

    oldestId = id;
  });

  return { newestId, oldestId };
};

// Neighbor in id order. Never coerces through Number(), so snowflakes stay strings.
export const nearestRealId = (items, anchorId) => {
  if (!isReal(anchorId)) {
    return { id: null, resolution: 'missing' };
  }

  let older = null;
  let newer = null;

  (items || []).forEach(id => {
    if (!isReal(id)) {
      return;
    }

    const order = compareId(id, anchorId);

    if (order === 0) {
      older = id;
      newer = null;
      return;
    }

    if (older === anchorId) {
      return;
    }

    if (order < 0 && (older === null || compareId(id, older) > 0)) {
      older = id;
    } else if (order > 0 && (newer === null || compareId(id, newer) < 0)) {
      newer = id;
    }
  });

  if (older === anchorId) {
    return { id: anchorId, resolution: 'exact' };
  }

  if (older) {
    return { id: older, resolution: 'nearest-older' };
  }

  if (newer) {
    return { id: newer, resolution: 'nearest-newer' };
  }

  return { id: null, resolution: 'missing' };
};

const expandRange = (items, anchorIndex, target) => {
  let start = anchorIndex;
  let end = anchorIndex + 1;
  let count = isReal(items[anchorIndex]) ? 1 : 0;

  while (count < target && (start > 0 || end < items.length)) {
    if (start > 0) {
      start -= 1;

      if (isReal(items[start])) {
        count += 1;
      }
    }

    if (count >= target) {
      break;
    }

    if (end < items.length) {
      if (isReal(items[end])) {
        count += 1;
      }

      end += 1;
    }
  }

  return { start, end };
};

const sameItems = (left, right) => {
  const before = left || [];
  const after = right || [];

  if (before.length !== after.length) {
    return false;
  }

  for (let index = 0; index < before.length; index += 1) {
    if (before[index] !== after[index]) {
      return false;
    }
  }

  return true;
};

const withRevision = (previous, previousItems, nextItems, windowState) => ({
  ...windowState,
  revision: (previous.revision || 0) + (sameItems(previousItems, nextItems) ? 0 : 1),
});

const blankWindow = (boundaryId, sourceHasMore) => ({
  generation: 1,
  revision: 0,
  anchorId: null,
  anchorResolution: 'unspecified',
  unbounded: false,
  boundaryId: boundaryId || null,
  newestId: null,
  oldestId: null,
  hasNewer: false,
  hasOlder: !!sourceHasMore,
  newer: edgeState(HISTORY_EDGE.EXHAUSTED),
  older: edgeState(sourceHasMore ? HISTORY_EDGE.OPEN : HISTORY_EDGE.EXHAUSTED),
});

export const selectInitialWindow = (items, anchorId, { target = WINDOW_TARGET, sourceHasMore = true, boundaryId = null } = {}) => {
  const list = Array.isArray(items) ? items.slice() : [];
  const resolved = isReal(anchorId) ? nearestRealId(list, anchorId) : { id: null, resolution: 'unspecified' };
  const edges = edgeIds(list);
  const boundary = boundaryId || edges.newestId;
  const base = blankWindow(boundary, sourceHasMore);
  const withinTarget = realCount(list) <= target;

  if (!resolved.id || withinTarget) {
    return {
      items: list,
      window: {
        ...base,
        anchorId: resolved.id,
        anchorResolution: resolved.resolution,
        // A missing reading position must not be replaced with the newest page.
        unbounded: !resolved.id && !withinTarget,
        newestId: edges.newestId,
        oldestId: edges.oldestId,
        hasNewer: false,
        hasOlder: !!sourceHasMore,
      },
    };
  }

  const anchorIndex = list.indexOf(resolved.id);

  if (anchorIndex < 0) {
    return {
      items: list,
      window: {
        ...base,
        anchorId: null,
        anchorResolution: 'missing',
        unbounded: true,
        newestId: edges.newestId,
        oldestId: edges.oldestId,
        hasNewer: false,
        hasOlder: !!sourceHasMore,
      },
    };
  }

  const range = expandRange(list, anchorIndex, target);
  const sliced = list.slice(range.start, range.end);
  const slicedEdges = edgeIds(sliced);
  const hasItemsBefore = list.slice(0, range.start).some(isReal);
  const reachedTail = !list.slice(range.end).some(isReal);
  const hasOlder = !reachedTail || !!sourceHasMore;

  return {
    items: sliced,
    window: {
      ...base,
      anchorId: resolved.id,
      anchorResolution: resolved.resolution,
      unbounded: false,
      newestId: slicedEdges.newestId,
      oldestId: slicedEdges.oldestId,
      hasNewer: hasItemsBefore,
      hasOlder,
      newer: edgeState(hasItemsBefore ? HISTORY_EDGE.OPEN : HISTORY_EDGE.EXHAUSTED, slicedEdges.newestId),
      older: edgeState(hasOlder ? HISTORY_EDGE.OPEN : HISTORY_EDGE.EXHAUSTED, slicedEdges.oldestId),
    },
  };
};

export const newestFirst = (ids) => (ids || []).filter(isReal).slice().sort((left, right) => compareId(right, left));

const uniqKeepGaps = (ids) => {
  const seen = new Set();

  return ids.filter(id => {
    if (!isReal(id)) {
      return true;
    }

    if (seen.has(id)) {
      return false;
    }

    seen.add(id);
    return true;
  });
};

const mergeNewestFirst = (oldIds, newIds, partial) => {
  if (!newIds.length) {
    return oldIds.slice();
  }

  const oldestNew = newIds[newIds.length - 1];
  const newestNew = newIds[0];
  const lastIndex = findLastIndex(oldIds, id => isReal(id) && compareId(id, oldestNew) >= 0) + 1;
  const head = oldIds.slice(0, lastIndex);
  const firstIndex = findLastIndex(head, id => isReal(id) && compareId(id, newestNew) > 0);

  if (firstIndex < 0) {
    return uniqKeepGaps([...(partial ? [null] : []), ...newIds, ...oldIds.slice(lastIndex)]);
  }

  const inserted = partial && oldIds[firstIndex] !== null ? [null, ...newIds] : newIds;

  return uniqKeepGaps([...oldIds.slice(0, firstIndex + 1), ...inserted, ...oldIds.slice(lastIndex)]);
};

const clearCoveredGaps = (items, pageIds) => {
  if (!pageIds.length) {
    return items;
  }

  const newest = pageIds[0];
  const oldest = pageIds[pageIds.length - 1];
  const covered = (id) => isReal(id) && compareId(id, newest) <= 0 && compareId(id, oldest) >= 0;

  return items.filter((id, index) => {
    if (id !== null) {
      return true;
    }

    const previous = findLastIndex(items.slice(0, index), isReal);
    const next = items.slice(index + 1).findIndex(isReal);
    const previousId = previous >= 0 ? items[previous] : null;
    const nextId = next >= 0 ? items[index + 1 + next] : null;

    return !(covered(previousId) && covered(nextId));
  });
};

const trimSide = (items, side, protect, limit) => {
  let next = items.slice();

  while (realCount(next) > limit) {
    if (side === 'newer') {
      const index = next.findIndex(isReal);

      if (index < 0 || next[index] === protect) {
        break;
      }

      next = next.slice(index + 1);
    } else {
      const index = findLastIndex(next, isReal);

      if (index < 0 || next[index] === protect) {
        break;
      }

      next = next.slice(0, index);
    }
  }

  return next;
};

const dropEdgeNulls = (items) => {
  let start = 0;
  let end = items.length;

  while (start < end && items[start] === null) {
    start += 1;
  }

  while (end > start && items[end - 1] === null) {
    end -= 1;
  }

  return items.slice(start, end);
};

export const trimWindow = (items, { protect, direction, target = WINDOW_TARGET, hardCap = WINDOW_HARD_CAP, keepEdgeGaps = false } = {}) => {
  const opposite = direction === 'older' ? 'newer' : 'older';
  let next = trimSide(items, opposite, protect, target);

  if (realCount(next) > hardCap) {
    next = trimSide(next, direction, protect, hardCap);
  }

  return keepEdgeGaps ? next : dropEdgeNulls(next);
};

const idsOnSide = (ids, cursor, direction, boundaryId) => newestFirst(ids).filter(id => {
  if (boundaryId && compareId(id, boundaryId) > 0) {
    return false;
  }

  if (!isReal(cursor)) {
    return true;
  }

  const order = compareId(id, cursor);

  return direction === 'newer' ? order > 0 : order < 0;
});

const classifyNewer = ({ ids, limit, partial, capability, boundaryId, newestAfter, previousNewest, pageIds }) => {
  if (partial && ids.length === 0) {
    return HISTORY_EDGE.PAUSED;
  }

  if (partial) {
    return HISTORY_EDGE.OPEN;
  }

  const crossedBoundary = (pageIds || []).some(id => isReal(id) && boundaryId && compareId(id, boundaryId) > 0);
  const atBoundary = !!(boundaryId && newestAfter && compareId(newestAfter, boundaryId) >= 0);

  if (crossedBoundary || atBoundary) {
    return HISTORY_EDGE.EXHAUSTED;
  }

  if (ids.length >= limit) {
    return HISTORY_EDGE.OPEN;
  }

  if (capability === HISTORY_CAPABILITY.REDIS && previousNewest && boundaryId && compareId(previousNewest, boundaryId) < 0) {
    return HISTORY_EDGE.UNAVAILABLE;
  }

  return HISTORY_EDGE.EXHAUSTED;
};

const classifyOlder = ({ ids, limit, partial, advanced, capability }) => {
  if (partial && ids.length === 0) {
    return HISTORY_EDGE.PAUSED;
  }

  if (partial) {
    return HISTORY_EDGE.OPEN;
  }

  // A short Redis page is the retained feed's edge. Posts older than
  // FeedManager::MAX_ITEMS may still exist, so this is not a true end.
  if (ids.length < limit) {
    return capability === HISTORY_CAPABILITY.REDIS ? HISTORY_EDGE.UNAVAILABLE : HISTORY_EDGE.EXHAUSTED;
  }

  if (!advanced) {
    return HISTORY_EDGE.UNAVAILABLE;
  }

  return HISTORY_EDGE.OPEN;
};

const resolutionFor = (items, anchorId, previous) => {
  if (!isReal(anchorId)) {
    return { anchorId: previous || null, anchorResolution: previous ? 'exact' : 'unspecified' };
  }

  const nearest = nearestRealId(items, anchorId);

  return {
    anchorId: nearest.id,
    anchorResolution: nearest.resolution,
  };
};

export const applyHistoryPage = (windowState, items, {
  pageIds = [],
  direction = 'older',
  partial = false,
  capability = HISTORY_CAPABILITY.DATABASE,
  limit = WINDOW_PAGE_LIMIT,
  anchorId = null,
  cursor = null,
  gap = false,
  target = WINDOW_TARGET,
  hardCap = WINDOW_HARD_CAP,
} = {}) => {
  const state = windowState;
  const acceptedIds = idsOnSide(pageIds, cursor, direction, state.boundaryId);
  let nextItems = mergeNewestFirst(items || [], acceptedIds, partial);

  if (!partial) {
    nextItems = clearCoveredGaps(nextItems, acceptedIds);
  }

  const previousNewest = state.newestId;
  const previousOldest = state.oldestId;
  let protect = direction === 'older' ? previousOldest : previousNewest;

  if (isReal(anchorId) && (nextItems.includes(anchorId) || (items || []).includes(anchorId))) {
    protect = anchorId;
  }

  if (!state.unbounded) {
    nextItems = trimWindow(nextItems, { protect, direction, target, hardCap, keepEdgeGaps: partial });
  }

  const edges = edgeIds(nextItems);
  const placed = resolutionFor(nextItems, protect, state.anchorId);
  let newer = { ...state.newer, requestId: null };
  let older = { ...state.older, requestId: null };
  const advancedOlder = !previousOldest || (!!edges.oldestId && compareId(edges.oldestId, previousOldest) < 0);

  if (direction === 'newer') {
    newer = {
      ...newer,
      status: classifyNewer({
        ids: acceptedIds,
        limit,
        partial,
        capability,
        boundaryId: state.boundaryId,
        newestAfter: edges.newestId,
        previousNewest,
        pageIds,
      }),
      cursor: edges.newestId,
    };
  } else if (!gap || cursor === previousOldest) {
    older = {
      ...older,
      status: classifyOlder({
        ids: acceptedIds,
        limit,
        partial,
        advanced: advancedOlder || acceptedIds.length === 0,
        capability,
      }),
      cursor: edges.oldestId,
    };
  } else {
    older = {
      ...older,
      status: state.older.status === HISTORY_EDGE.LOADING ? HISTORY_EDGE.OPEN : state.older.status,
    };
  }

  const trimmedNewer = !!(previousNewest && edges.newestId && compareId(edges.newestId, previousNewest) < 0);
  const trimmedOlder = !!(previousOldest && edges.oldestId && compareId(edges.oldestId, previousOldest) > 0);

  if (trimmedNewer) {
    newer = { ...newer, status: HISTORY_EDGE.OPEN, cursor: edges.newestId };
  }

  if (trimmedOlder && (older.status === HISTORY_EDGE.EXHAUSTED || older.status === HISTORY_EDGE.UNAVAILABLE)) {
    older = { ...older, status: HISTORY_EDGE.OPEN, cursor: edges.oldestId };
  }

  const hasNewer = newer.status !== HISTORY_EDGE.EXHAUSTED;
  const hasOlder = older.status !== HISTORY_EDGE.EXHAUSTED;

  return {
    items: nextItems,
    window: withRevision(state, items, nextItems, {
      ...state,
      anchorId: placed.anchorId,
      anchorResolution: placed.anchorResolution,
      newestId: edges.newestId,
      oldestId: edges.oldestId,
      hasNewer,
      hasOlder,
      newer,
      older,
    }),
  };
};

export const beginHistoryRequest = (windowState, { direction, cursor, requestId, anchorId = null, gap = false } = {}) => {
  const edge = windowState[direction];

  if (!edge || !isReal(cursor) || !requestId) {
    return { accepted: false, window: windowState };
  }

  if (windowState.unbounded) {
    return { accepted: false, window: windowState };
  }

  const opposite = direction === 'newer' ? windowState.older : windowState.newer;

  if (opposite && opposite.status === HISTORY_EDGE.LOADING) {
    return { accepted: false, window: windowState };
  }

  if (!gap && edge.status === HISTORY_EDGE.EXHAUSTED) {
    return { accepted: false, window: windowState };
  }

  if (edge.status === HISTORY_EDGE.LOADING && edge.cursor === cursor && edge.requestId) {
    return { accepted: false, window: windowState };
  }

  return {
    accepted: true,
    window: {
      ...windowState,
      anchorId: isReal(anchorId) ? anchorId : windowState.anchorId,
      [direction]: {
        status: HISTORY_EDGE.LOADING,
        requestId,
        cursor,
      },
    },
  };
};

export const responseIsCurrent = (windowState, { generation, requestId, direction } = {}) => {
  if (!windowState || !direction) {
    return false;
  }

  if (generation !== windowState.generation) {
    return false;
  }

  return windowState[direction] && windowState[direction].requestId === requestId;
};

export const failHistoryRequest = (windowState, { direction, requestId, generation } = {}) => {
  if (!responseIsCurrent(windowState, { generation, requestId, direction })) {
    return windowState;
  }

  return {
    ...windowState,
    [direction]: {
      ...windowState[direction],
      status: HISTORY_EDGE.ERROR,
      requestId: null,
    },
  };
};

export const refreshHistoryEdges = (items, windowState) => {
  if (!windowState) {
    return windowState;
  }

  const edges = edgeIds(items);
  const placed = isReal(windowState.anchorId) ? nearestRealId(items, windowState.anchorId) : { id: windowState.anchorId, resolution: windowState.anchorResolution };

  return {
    ...windowState,
    anchorId: placed.id,
    anchorResolution: placed.resolution,
    newestId: edges.newestId,
    oldestId: edges.oldestId,
  };
};

const nullFollows = (items, cursor) => {
  const index = (items || []).indexOf(cursor);

  if (index < 0) {
    return false;
  }

  for (let position = index + 1; position < items.length; position += 1) {
    if (items[position] === null) {
      return true;
    }

    if (isReal(items[position])) {
      return false;
    }
  }

  return false;
};

// Filtered status lists are not cursors. A gap id is used only when a null
// marker actually follows it in the raw history items.
export const resolveCursor = (items, windowState, direction, gapCursor) => {
  if (!windowState) {
    return null;
  }

  if (direction === 'newer') {
    return windowState.newestId;
  }

  if (isReal(gapCursor) && gapCursor !== windowState.oldestId && nullFollows(items, gapCursor)) {
    return gapCursor;
  }

  return windowState.oldestId;
};

const realOnly = (items) => (items || []).filter(isReal);

const gapBetween = (items, newerId, olderId) => {
  const start = items.indexOf(newerId);
  const end = items.indexOf(olderId);

  if (start < 0 || end <= start) {
    return false;
  }

  for (let index = start + 1; index < end; index += 1) {
    if (items[index] === null) {
      return true;
    }
  }

  return false;
};

export const mergeIdLists = (sourceItems, historyItems) => {
  const sourceReal = realOnly(sourceItems);
  const historyReal = realOnly(historyItems);
  const merged = [];
  let sourceIndex = 0;
  let historyIndex = 0;

  while (sourceIndex < sourceReal.length || historyIndex < historyReal.length) {
    const sourceId = sourceReal[sourceIndex];
    const historyId = historyReal[historyIndex];

    if (sourceId === undefined) {
      merged.push(historyId);
      historyIndex += 1;
      continue;
    }

    if (historyId === undefined) {
      merged.push(sourceId);
      sourceIndex += 1;
      continue;
    }

    const order = compareId(sourceId, historyId);

    if (order === 0) {
      merged.push(sourceId);
      sourceIndex += 1;
      historyIndex += 1;
    } else if (order > 0) {
      merged.push(sourceId);
      sourceIndex += 1;
    } else {
      merged.push(historyId);
      historyIndex += 1;
    }
  }

  const withGaps = [];

  merged.forEach((id, index) => {
    withGaps.push(id);
    const next = merged[index + 1];

    if (next && (gapBetween(sourceItems, id, next) || gapBetween(historyItems, id, next))) {
      withGaps.push(null);
    }
  });

  return withGaps;
};

const preserveEdgeNulls = (merged, ...lists) => {
  let next = merged.slice();
  const lead = lists.some(list => list && list[0] === null);
  const trail = lists.some(list => list && list.length > 0 && list[list.length - 1] === null);

  if (lead && next[0] !== null) {
    next = [null, ...next];
  }

  if (trail && next[next.length - 1] !== null) {
    next = [...next, null];
  }

  return next;
};

// Source ids newer than the split boundary stay pending. History contributes
// ids the window loaded, including ones outside the current source list.
// Leading and trailing null gaps are kept so a partial marker is not dropped.
export const reconcileHistoryItems = (sourceItems, historyItems, boundaryId) => {
  const inHistory = new Set(realOnly(historyItems));
  const sourceKept = [];

  (sourceItems || []).forEach(id => {
    if (!isReal(id)) {
      sourceKept.push(id);
      return;
    }

    if (inHistory.has(id) || (boundaryId && compareId(id, boundaryId) <= 0)) {
      sourceKept.push(id);
    }
  });

  return preserveEdgeNulls(mergeIdLists(sourceKept, historyItems || []), sourceItems || [], historyItems || []);
};

export const reconcileHasMore = (sourceHasMore, sourceItems, historyItems, windowState) => {
  const sourceOldest = edgeIds(sourceItems).oldestId;
  const historyOldest = edgeIds(historyItems).oldestId;
  const extended = !!historyOldest && (!sourceOldest || compareId(historyOldest, sourceOldest) < 0);

  if (!extended || !windowState) {
    return !!sourceHasMore;
  }

  return windowState.older.status !== HISTORY_EDGE.EXHAUSTED;
};

const realIndexes = (items) => {
  const indexes = [];

  (items || []).forEach((id, index) => {
    if (isReal(id)) {
      indexes.push(index);
    }
  });

  return indexes;
};

// No reading row was found. Keep a middle slice instead of the newest page,
// and stop the unbounded copy from growing.
export const capUnresolvedWindow = (items, windowState, { hardCap = WINDOW_HARD_CAP } = {}) => {
  const list = items || [];
  const indexes = realIndexes(list);
  const state = windowState;
  let sliced = list;
  let droppedNewer = 0;
  let droppedOlder = false;

  if (indexes.length > hardCap) {
    const extra = indexes.length - hardCap;
    droppedNewer = Math.floor(extra / 2);
    const start = indexes[droppedNewer];
    const end = indexes[droppedNewer + hardCap - 1] + 1;

    sliced = list.slice(start, end);
    droppedOlder = droppedNewer + hardCap < indexes.length;
  }

  const edges = edgeIds(sliced);
  const hasNewer = droppedNewer > 0;
  const hasOlder = droppedOlder || !!state.hasOlder;

  return {
    items: sliced,
    window: {
      ...state,
      unbounded: false,
      anchorId: null,
      anchorResolution: 'missing',
      newestId: edges.newestId,
      oldestId: edges.oldestId,
      hasNewer,
      hasOlder,
      newer: edgeState(hasNewer ? HISTORY_EDGE.OPEN : HISTORY_EDGE.EXHAUSTED, edges.newestId),
      older: edgeState(hasOlder ? HISTORY_EDGE.OPEN : HISTORY_EDGE.EXHAUSTED, edges.oldestId),
    },
  };
};

const finishAnchorPlacement = (previousItems, placed, previousWindow) => ({
  items: placed.items,
  window: withRevision(previousWindow, previousItems, placed.items, placed.window),
});

export const commitHistoryAnchor = (items, windowState, anchorId, { target = WINDOW_TARGET, sourceHasMore, hardCap = WINDOW_HARD_CAP } = {}) => {
  if (!windowState) {
    return null;
  }

  if (!isReal(anchorId)) {
    if (!windowState.unbounded) {
      return { items, window: windowState };
    }

    return finishAnchorPlacement(items, capUnresolvedWindow(items, windowState, { hardCap }), windowState);
  }

  if (!windowState.unbounded) {
    if (!windowState.anchorId && isReal(anchorId)) {
      return {
        items,
        window: {
          ...windowState,
          anchorId,
          anchorResolution: 'exact',
        },
      };
    }

    return { items, window: windowState };
  }

  const hasMore = sourceHasMore !== undefined ? sourceHasMore : windowState.hasOlder;
  const selected = selectInitialWindow(items, anchorId, {
    target,
    sourceHasMore: hasMore,
    boundaryId: windowState.boundaryId,
  });

  return finishAnchorPlacement(items, {
    items: selected.items,
    window: {
      ...selected.window,
      generation: windowState.generation,
      boundaryId: windowState.boundaryId,
    },
  }, windowState);
};
