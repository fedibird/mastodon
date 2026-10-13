import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import api from '../api';
import { importFetchedStatus } from './importer';
import {
  IMMEDIATE_FEED_TTL_MS,
  buildGroupImmediateView,
  buildHashtagImmediateView,
  immediateStatusDecision,
} from '../immediate_feed/eligibility';
import { RECONCILE_MAX_PAGES, RECONCILE_PAGE_LIMIT, walkTimelineForStatus } from '../immediate_feed/reconcile';

export const IMMEDIATE_FEED_REGISTER_VIEW = 'IMMEDIATE_FEED_REGISTER_VIEW';
export const IMMEDIATE_FEED_UNREGISTER_VIEW = 'IMMEDIATE_FEED_UNREGISTER_VIEW';
export const IMMEDIATE_FEED_INSERT = 'IMMEDIATE_FEED_INSERT';
export const IMMEDIATE_FEED_EXPIRE = 'IMMEDIATE_FEED_EXPIRE';
export const IMMEDIATE_FEED_RECHECK = 'IMMEDIATE_FEED_RECHECK';
export const IMMEDIATE_FEED_REMOVE = 'IMMEDIATE_FEED_REMOVE';
export const IMMEDIATE_FEED_CONFIRM = 'IMMEDIATE_FEED_CONFIRM';

export { buildGroupImmediateView, buildHashtagImmediateView, IMMEDIATE_FEED_TTL_MS };

const timers = new Map();

const timerKey = (viewKey, statusId) => `${viewKey}\u0000${statusId}`;

let nextGeneration = 1;
let nextRegistrationGeneration = 1;

const allocateGeneration = () => {
  const generation = nextGeneration;

  nextGeneration += 1;

  return generation;
};

const clearTimerRecord = (key) => {
  const record = timers.get(key);

  if (!record) {
    return;
  }

  clearTimeout(record.handle);
  timers.delete(key);
};

export function cancelImmediateFeedTimer (viewKey, statusId) {
  clearTimerRecord(timerKey(viewKey, statusId));
}

export function cancelImmediateFeedViewTimers (viewKey) {
  const prefix = `${viewKey}\u0000`;

  Array.from(timers.keys()).forEach(key => {
    if (key.indexOf(prefix) === 0) {
      clearTimerRecord(key);
    }
  });
}

export function cancelImmediateFeedTimersForStatuses (statusIds) {
  const wanted = new Set((statusIds || []).filter(id => id !== null && id !== undefined).map(id => String(id)));

  if (wanted.size === 0) {
    return;
  }

  Array.from(timers.entries()).forEach(([key, record]) => {
    if (wanted.has(String(record.statusId))) {
      clearTimerRecord(key);
    }
  });
}

export function cancelImmediateFeedTimersForTimeline (timelineId) {
  Array.from(timers.entries()).forEach(([key, record]) => {
    if (record.timelineId === timelineId) {
      clearTimerRecord(key);
    }
  });
}

const scheduleReconcile = (dispatch, viewKey, statusId, generation, timelineId) => {
  cancelImmediateFeedTimer(viewKey, statusId);

  const handle = setTimeout(() => {
    timers.delete(timerKey(viewKey, statusId));
    dispatch(reconcileImmediateEntry(viewKey, statusId, generation));
  }, IMMEDIATE_FEED_TTL_MS);

  timers.set(timerKey(viewKey, statusId), {
    handle,
    statusId: String(statusId),
    timelineId,
    viewKey,
    generation,
  });
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
  if (view && view.viewKey) {
    cancelImmediateFeedViewTimers(view.viewKey);
  }

  const registrationGeneration = nextRegistrationGeneration;

  nextRegistrationGeneration += 1;

  return {
    type: IMMEDIATE_FEED_REGISTER_VIEW,
    view: {
      ...view,
      registrationGeneration,
    },
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
    registrationGeneration: view.get('registrationGeneration'),
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

    // A → B → A reuses the filter signature on a new registration.
    // The original send must not land in that later session.
    if (view.get('registrationGeneration') !== snapshot.registrationGeneration) {
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
      registrationGeneration: snapshot.registrationGeneration,
      requestId: snapshot.requestId,
    });

    if (phase === 'immediate') {
      scheduleReconcile(dispatch, snapshot.viewKey, statusId, generation, snapshot.timelineId);
    }
  };
}

const entryStillCurrent = (state, viewKey, statusId, generation) => {
  const entry = state.getIn(['immediate_feed', 'entries', immediateFeedEntryKey(viewKey, statusId)]);

  if (!entry || entry.get('generation') !== generation) {
    return null;
  }

  if (entry.get('phase') !== 'immediate' && entry.get('phase') !== 'recheck') {
    return null;
  }

  const view = state.getIn(['immediate_feed', 'views', viewKey]);

  if (!view || view.get('registrationGeneration') !== entry.get('registrationGeneration')) {
    return null;
  }

  return { entry, view };
};

const timelineRequestForView = (view) => {
  const filters = view.get('filters').toJS();

  if (view.get('kind') === 'hashtag') {
    return {
      url: `/api/v1/timelines/tag/${encodeURIComponent(filters.primary)}`,
      params: {
        limit: RECONCILE_PAGE_LIMIT,
        any: filters.any || [],
        all: filters.all || [],
        none: filters.none || [],
      },
    };
  }

  return {
    url: `/api/v1/timelines/group/${encodeURIComponent(filters.groupId)}`,
    params: {
      limit: RECONCILE_PAGE_LIMIT,
      only_media: filters.onlyMedia ? true : undefined,
      without_media: filters.withoutMedia ? true : undefined,
      tagged: filters.tagged || undefined,
    },
  };
};

const idsFromTimelinePayload = (data) => {
  const list = data && data.statuses ? data.statuses : data;

  if (!Array.isArray(list)) {
    return { ids: [], statuses: [] };
  }

  return {
    ids: list.map(status => (status && status.id !== undefined ? status.id : status)),
    statuses: list.filter(status => status && typeof status === 'object'),
  };
};

export function reconcileImmediateEntry (viewKey, statusId, generation) {
  return (dispatch, getState) => {
    const current = entryStillCurrent(getState(), viewKey, statusId, generation);

    if (!current) {
      cancelImmediateFeedTimer(viewKey, statusId);
      return Promise.resolve();
    }

    dispatch({
      type: IMMEDIATE_FEED_RECHECK,
      viewKey,
      statusId,
      generation,
    });

    const request = timelineRequestForView(current.view);
    const pages = [];

    const loadPage = (maxId) => api(getState()).get(request.url, {
      params: {
        ...request.params,
        max_id: maxId || undefined,
      },
    }).then(response => {
      const parsed = idsFromTimelinePayload(response.data);

      pages.push({
        ids: parsed.ids,
        statuses: parsed.statuses,
      });

      return parsed.ids;
    });

    const step = (maxId, remaining) => {
      if (remaining <= 0) {
        return Promise.resolve(walkTimelineForStatus(statusId, pages));
      }

      return loadPage(maxId).then(ids => {
        const assessed = walkTimelineForStatus(statusId, pages);

        if (assessed.outcome !== 'continue') {
          return assessed;
        }

        const oldest = ids.length ? ids[ids.length - 1] : null;

        if (!oldest) {
          return { outcome: 'inconclusive', status: null };
        }

        return step(oldest, remaining - 1);
      });
    };

    return step(null, RECONCILE_MAX_PAGES).then(result => {
      const latest = entryStillCurrent(getState(), viewKey, statusId, generation);

      if (!latest) {
        cancelImmediateFeedTimer(viewKey, statusId);
        return;
      }

      if (result.outcome === 'confirmed') {
        if (result.status) {
          dispatch(importFetchedStatus(result.status));
        }

        dispatch({
          type: IMMEDIATE_FEED_CONFIRM,
          viewKey,
          statusId,
          generation,
        });
        cancelImmediateFeedTimer(viewKey, statusId);
        return;
      }

      if (result.outcome === 'excluded') {
        dispatch({
          type: IMMEDIATE_FEED_REMOVE,
          viewKey,
          statusId,
          generation,
        });
        cancelImmediateFeedTimer(viewKey, statusId);
        return;
      }

      scheduleReconcile(dispatch, viewKey, statusId, generation, latest.entry.get('timelineId'));
    }).catch(() => {
      const latest = entryStillCurrent(getState(), viewKey, statusId, generation);

      if (!latest) {
        cancelImmediateFeedTimer(viewKey, statusId);
        return;
      }

      scheduleReconcile(dispatch, viewKey, statusId, generation, latest.entry.get('timelineId'));
    });
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
