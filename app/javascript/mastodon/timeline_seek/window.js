import compareId from '../compare_id';
import { isDecimalStatusId } from '../timeline_navigation';
import { HISTORY_CAPABILITY, HISTORY_EDGE } from '../windowed_history/constants';

const includesId = (ids, id) => {
  if (!ids) {
    return false;
  }

  if (typeof ids.has === 'function' && !Array.isArray(ids)) {
    return ids.has(id);
  }

  if (typeof ids.indexOf === 'function') {
    return ids.indexOf(id) !== -1;
  }

  return false;
};

export const assembleSeekItems = (anchorId, newerIds, olderIds, boundaryId) => {
  const ids = [];

  const push = (id) => {
    if (!isDecimalStatusId(id) || ids.indexOf(id) !== -1) {
      return;
    }

    if (boundaryId && isDecimalStatusId(boundaryId) && compareId(id, boundaryId) > 0) {
      return;
    }

    ids.push(id);
  };

  (newerIds || []).forEach(push);
  push(anchorId);
  (olderIds || []).forEach(push);
  ids.sort((left, right) => compareId(right, left));

  return ids;
};

export const edgeStatusForSeekPage = ({
  ids,
  limit,
  partial = false,
  capability = HISTORY_CAPABILITY.DATABASE,
  direction,
  boundaryId,
  edgeId,
} = {}) => {
  const page = ids || [];

  if (partial && page.length === 0) {
    return HISTORY_EDGE.PAUSED;
  }

  if (partial) {
    return HISTORY_EDGE.OPEN;
  }

  if (direction === 'newer' && boundaryId && edgeId && compareId(edgeId, boundaryId) >= 0) {
    return HISTORY_EDGE.EXHAUSTED;
  }

  if (page.length >= limit) {
    return HISTORY_EDGE.OPEN;
  }

  // A short Redis page is the retained feed, not the end of the author's posts.
  if (capability === HISTORY_CAPABILITY.REDIS) {
    return HISTORY_EDGE.UNAVAILABLE;
  }

  return HISTORY_EDGE.EXHAUSTED;
};

const realEdge = (items) => {
  let newestId = null;
  let oldestId = null;

  (items || []).forEach(id => {
    if (!isDecimalStatusId(id)) {
      return;
    }

    if (newestId === null) {
      newestId = id;
    }

    oldestId = id;
  });

  return { newestId, oldestId };
};

export const commitSeekWindow = (windowState, {
  anchorId,
  newerIds,
  olderIds,
  newerPartial = false,
  olderPartial = false,
  limit,
  capability = HISTORY_CAPABILITY.DATABASE,
} = {}) => {
  if (!windowState || !isDecimalStatusId(anchorId)) {
    return { committed: false, items: null, window: windowState };
  }

  const items = assembleSeekItems(anchorId, newerIds, olderIds, windowState.boundaryId);

  if (items.indexOf(anchorId) < 0) {
    return { committed: false, items: null, window: windowState };
  }

  const edges = realEdge(items);
  const newerPage = (newerIds || []).filter(id => items.indexOf(id) !== -1 && id !== anchorId);
  const olderPage = (olderIds || []).filter(id => items.indexOf(id) !== -1 && id !== anchorId);
  const newerStatus = edgeStatusForSeekPage({
    ids: newerPage,
    limit,
    partial: newerPartial,
    capability,
    direction: 'newer',
    boundaryId: windowState.boundaryId,
    edgeId: edges.newestId,
  });
  const olderStatus = edgeStatusForSeekPage({
    ids: olderPage,
    limit,
    partial: olderPartial,
    capability,
    direction: 'older',
  });

  return {
    committed: true,
    items,
    window: {
      ...windowState,
      seeking: false,
      revision: (windowState.revision || 0) + 1,
      anchorId,
      anchorResolution: 'exact',
      unbounded: false,
      newestId: edges.newestId,
      oldestId: edges.oldestId,
      hasNewer: newerStatus !== HISTORY_EDGE.EXHAUSTED,
      hasOlder: olderStatus !== HISTORY_EDGE.EXHAUSTED,
      newer: { status: newerStatus, requestId: null, cursor: edges.newestId },
      older: { status: olderStatus, requestId: null, cursor: edges.oldestId },
    },
  };
};

export const seekIsCurrent = ({ active, sessionId, phase, generation, windowGeneration, recordedSource, source } = {}) => (
  !!active
  && phase === 'pending'
  && !!sessionId
  && generation === windowGeneration
  && recordedSource === source
);

// Filtered or missing rows report a result and do not ask the scroller to move.
export const planSeekScroll = ({ anchorId, loadedIds, visibleIds } = {}) => {
  if (!isDecimalStatusId(anchorId)) {
    return { scroll: false, reason: 'invalid' };
  }

  if (loadedIds && !includesId(loadedIds, anchorId)) {
    return { scroll: false, reason: 'missing_row' };
  }

  if (visibleIds && !includesId(visibleIds, anchorId)) {
    return { scroll: false, reason: 'filtered' };
  }

  return { scroll: true, reason: 'loaded', anchorId };
};
