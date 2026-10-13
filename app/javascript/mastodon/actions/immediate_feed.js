import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import { importFetchedStatus } from './importer';
import {
  IMMEDIATE_FEED_TTL_MS,
  buildGroupImmediateView,
  buildHashtagImmediateView,
  immediateStatusDecision,
} from '../immediate_feed/eligibility';

export const IMMEDIATE_FEED_REGISTER_VIEW = 'IMMEDIATE_FEED_REGISTER_VIEW';
export const IMMEDIATE_FEED_UNREGISTER_VIEW = 'IMMEDIATE_FEED_UNREGISTER_VIEW';
export const IMMEDIATE_FEED_INSERT = 'IMMEDIATE_FEED_INSERT';
export const IMMEDIATE_FEED_EXPIRE = 'IMMEDIATE_FEED_EXPIRE';

export { buildGroupImmediateView, buildHashtagImmediateView, IMMEDIATE_FEED_TTL_MS };

const timers = new Map();

const timerKey = (viewKey, statusId) => `${viewKey}\u0000${statusId}`;

let nextGeneration = 1;

const allocateGeneration = () => {
  const generation = nextGeneration;

  nextGeneration += 1;

  return generation;
};

export function cancelImmediateFeedTimer (viewKey, statusId) {
  const key = timerKey(viewKey, statusId);
  const handle = timers.get(key);

  if (handle) {
    clearTimeout(handle);
    timers.delete(key);
  }
}

export function cancelImmediateFeedViewTimers (viewKey) {
  const prefix = `${viewKey}\u0000`;

  Array.from(timers.keys()).forEach(key => {
    if (key.indexOf(prefix) === 0) {
      clearTimeout(timers.get(key));
      timers.delete(key);
    }
  });
}

const scheduleExpiry = (dispatch, viewKey, statusId, generation) => {
  cancelImmediateFeedTimer(viewKey, statusId);

  const handle = setTimeout(() => {
    timers.delete(timerKey(viewKey, statusId));
    dispatch({
      type: IMMEDIATE_FEED_EXPIRE,
      viewKey,
      statusId,
      generation,
    });
  }, IMMEDIATE_FEED_TTL_MS);

  timers.set(timerKey(viewKey, statusId), handle);
};

const viewsMatch = (previous, next) => (
  previous &&
  next &&
  previous.viewKey === next.viewKey &&
  previous.timelineId === next.timelineId &&
  previous.filterSignature === next.filterSignature &&
  previous.localGroup === next.localGroup
);

export function registerImmediateFeedView (view) {
  return {
    type: IMMEDIATE_FEED_REGISTER_VIEW,
    view,
  };
}

export function unregisterImmediateFeedView (viewKey) {
  cancelImmediateFeedViewTimers(viewKey);

  return {
    type: IMMEDIATE_FEED_UNREGISTER_VIEW,
    viewKey,
  };
}

export function syncImmediateFeedView (dispatch, previousView, nextView) {
  if (!nextView || !nextView.viewKey) {
    return;
  }

  if (previousView && previousView.viewKey !== nextView.viewKey) {
    dispatch(unregisterImmediateFeedView(previousView.viewKey));
  }

  if (!viewsMatch(previousView, nextView)) {
    dispatch(registerImmediateFeedView(nextView));
  }
}

const blockedByGroup = (state, groupId) => {
  const relationship = state.getIn(['relationships', String(groupId)]);

  if (!relationship || !relationship.get) {
    return false;
  }

  return relationship.get('blocked_by') === true;
};

// Closed over by the submit request. Response handling must not read the
// composer, the current column, or the current identity again.
export function captureImmediateFeedSnapshot (state, composerId, composer) {
  if (!composer || !composer.get) {
    return null;
  }

  if (composer.get('id')) {
    return null;
  }

  const kind = composer.getIn(['surface', 'kind']);

  if (kind !== 'hashtag' && kind !== 'group') {
    return null;
  }

  const view = state.getIn(['immediate_feed', 'views', composerId]);

  if (!view || !view.get) {
    return null;
  }

  if (view.get('kind') !== kind) {
    return null;
  }

  const filters = view.get('filters');
  const plainFilters = filters && filters.toJS ? filters.toJS() : null;

  if (!plainFilters) {
    return null;
  }

  const groupId = plainFilters.groupId;

  return {
    composerId,
    requestId: composer.get('idempotencyKey') || null,
    surfaceEpoch: composer.get('surfaceEpoch') || 0,
    surface: {
      kind,
      key: composer.getIn(['surface', 'key']) || null,
    },
    postingContextKey: composer.getIn(['context', 'key']) || null,
    postingContextRevision: composer.getIn(['context', 'source', 'revision']) || null,
    postingContextAccountId: composer.get('posting_context_account_id') || null,
    senderIdentityId: composer.getIn(['senderIdentity', 'id']) || null,
    viewKey: composerId,
    timelineId: view.get('timelineId'),
    kind,
    localGroup: view.get('localGroup') === true,
    filterSignature: view.get('filterSignature'),
    filters: plainFilters,
    blockedByGroup: kind === 'group' ? blockedByGroup(state, groupId) : false,
  };
}

const sameId = (left, right) => left !== null && left !== undefined && String(left) === String(right);

const timelineListsStatus = (timeline, statusId) => {
  if (!timeline || !timeline.get) {
    return false;
  }

  const items = timeline.get('items', ImmutableList());
  const pending = timeline.get('pendingItems', ImmutableList());

  return items.some(id => sameId(id, statusId)) || pending.some(id => sameId(id, statusId));
};

export function publishImmediateStatus (snapshot, status) {
  return (dispatch, getState) => {
    if (!snapshot || !status || !status.id || status.scheduled_at) {
      return;
    }

    const state = getState();
    const view = state.getIn(['immediate_feed', 'views', snapshot.viewKey]);

    if (!view || !view.get) {
      return;
    }

    // The column's filters or timeline changed while the request was in flight.
    // Keep the post out of the new destination.
    if (view.get('timelineId') !== snapshot.timelineId || view.get('filterSignature') !== snapshot.filterSignature || view.get('kind') !== snapshot.kind) {
      return;
    }

    if (state.getIn(['timelines', snapshot.timelineId, 'isPartial'])) {
      return;
    }

    if (!immediateStatusDecision(snapshot, status).eligible) {
      return;
    }

    const statusId = String(status.id);
    const generation = allocateGeneration();
    const alreadyListed = timelineListsStatus(state.getIn(['timelines', snapshot.timelineId], ImmutableMap()), statusId);
    const phase = alreadyListed ? 'confirmed' : 'immediate';

    dispatch(importFetchedStatus(status, { acceptPresentationChange: false }));
    dispatch({
      type: IMMEDIATE_FEED_INSERT,
      viewKey: snapshot.viewKey,
      timelineId: snapshot.timelineId,
      statusId,
      phase,
      generation,
      requestId: snapshot.requestId,
    });

    if (phase === 'immediate') {
      scheduleExpiry(dispatch, snapshot.viewKey, statusId, generation);
    }
  };
}

export function immediateFeedEntryKey (viewKey, statusId) {
  return `${viewKey}\u0000${statusId}`;
}

export function immediateFeedViewFromAction (action) {
  if (!action || !action.view) {
    return null;
  }

  return fromJS(action.view);
}
