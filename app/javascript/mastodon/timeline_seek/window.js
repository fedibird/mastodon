import compareId from '../compare_id';
import { isDecimalStatusId } from '../timeline_navigation';
import { HISTORY_CAPABILITY, HISTORY_EDGE } from '../windowed_history/constants';

const includesId = (ids, id) => {
  if (!ids) {
    return false;
  }

  // List.has is an index check. indexOf is value membership for Array and List.
  if (typeof ids.indexOf === 'function') {
    return ids.indexOf(id) !== -1;
  }

  if (typeof ids.has === 'function') {
    return ids.has(id);
  }

  return false;
};

// The split history window stops at its boundary. A newer id belongs to the
// live column, and a successful resolve must not be applied there.
export const anchorBeyondSplitBoundary = (anchorId, boundaryId) => (
  isDecimalStatusId(anchorId)
  && isDecimalStatusId(boundaryId)
  && compareId(anchorId, boundaryId) > 0
);

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

// Called after the new window has been rendered. An id missing from the
// filtered list is filtered. An id in that list whose article is not in the
// DOM yet is not_loaded, which is not a filter result and does not move.
export const planSeekScroll = ({ anchorId, renderedIds, articlePresent } = {}) => {
  if (!isDecimalStatusId(anchorId)) {
    return { scroll: false, reason: 'invalid' };
  }

  if (renderedIds && !includesId(renderedIds, anchorId)) {
    return { scroll: false, reason: 'filtered' };
  }

  if (articlePresent === false) {
    return { scroll: false, reason: 'not_loaded' };
  }

  return { scroll: true, reason: 'loaded', anchorId };
};
