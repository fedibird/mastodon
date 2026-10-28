import api from '../api';
import { fetchRelationshipsSuccess } from './accounts';
import { importFetchedAccounts, importFetchedStatuses, importFilters } from './importer';
import { getHomeVisibilities } from '../selectors';
import {
  TIMELINE_EXTERNAL_CLEAR_VIEW,
  TIMELINE_EXTERNAL_RECONCILE,
  clearDeferredExternalReconnectsForTests,
} from './timelines';
import { MIX_EXTERNAL_RECONCILE } from './mix_timelines';
import { reconcileHeldExternalBoosts, resetExternalBoostReconcile } from './external_boosts';
import { plainMix } from '../mix/definition';
import { sourceKey } from '../mix/source';
import { normalizePage, previousStatusesForImport, resolveRequest, statusesForSharedImport, visibilityConstraints } from '../mix/adapter';
import { classifyStreamStatus } from '../mix/stream_adapters';
import { externalFeedSession } from '../external_feeds/session';
import {
  BATCHES_PER_CYCLE,
  BODY_BATCH,
  HISTORY_PAGE_SIZE,
  HISTORY_PAGES_PER_CYCLE,
  MEMBERSHIP_BATCH,
  budgetChunks,
  exhaustedTailSegment,
  loadedRanges,
  nextExhaustedPage,
  nextHistoryCursor,
  parseControl,
  placeReconcileIds,
  planMembership,
  protectStatusBodies,
  responsePreservesDisplayed,
} from '../external_feeds/reconcile';

export const EXTERNAL_FEEDS_PERMITTED = 'EXTERNAL_FEEDS_PERMITTED';

const retries = new Map();
let capabilityTimer = null;
let visibilityHandler = null;

const httpClient = (getState) => {
  try {
    const client = api(getState);

    if (!client || typeof client.get !== 'function' || typeof client.post !== 'function') {
      return null;
    }

    return client;
  } catch (error) {
    return null;
  }
};

const uniqueIds = (lists) => {
  const seen = new Set();
  const ids = [];

  lists.forEach(list => {
    if (!list || !list.forEach) {
      return;
    }

    list.forEach(id => {
      if (!id || seen.has(id)) {
        return;
      }

      seen.add(id);
      ids.push(String(id));
    });
  });

  return ids;
};

const timelineHeldIds = (state, timeline) => {
  const split = state.getIn(['timelines', timeline, 'splitTimelineId']);

  return uniqueIds([
    state.getIn(['timelines', timeline, 'pendingItems']),
    state.getIn(['timelines', timeline, 'items']),
    split && state.getIn(['timelines', split, 'pendingItems']),
    split && state.getIn(['timelines', split, 'items']),
  ]);
};

const mixHeldIds = (state, columnKey, key) => uniqueIds([
  state.getIn(['mix_timelines', columnKey, 'sources', key, 'ids']),
  state.getIn(['mix_timelines', columnKey, 'live', key, 'statusIds']),
  state.getIn(['mix_timelines', columnKey, 'split', 'history', 'sources', key, 'ids']),
  state.getIn(['mix_timelines', columnKey, 'split', 'history', 'frozenLive', key, 'ids']),
]);

const permittedNow = (state) => state.getIn(['externalFeeds', 'permitted']) === true;

const findMix = (state, mixId) => (
  state.getIn(['settings', 'mixes']) && state.getIn(['settings', 'mixes']).find(item => item && item.get('id') === String(mixId))
);

const scheduleRetry = (dispatch, key, token) => {
  if (retries.has(key)) {
    return;
  }

  const timer = setTimeout(() => {
    retries.delete(key);
    dispatch(runExternalReconcile(key, token));
  }, 2000);

  retries.set(key, timer);
};

const clearRetry = (key) => {
  const timer = retries.get(key);

  if (timer) {
    clearTimeout(timer);
    retries.delete(key);
  }
};

export function openExternalFeedView (key, meta) {
  return (dispatch) => {
    clearRetry(key);
    const token = externalFeedSession.open(key, meta);

    dispatch(runExternalReconcile(key, token));
    return token;
  };
}

export function closeExternalFeedView (key, token) {
  return () => {
    clearRetry(key);
    externalFeedSession.close(key, token);
  };
}

export function invalidateExternalFeedView (key) {
  return () => {
    externalFeedSession.invalidate(key);
  };
}

const clearExternalFeedTimers = () => {
  retries.forEach(timer => clearTimeout(timer));
  retries.clear();

  if (capabilityTimer) {
    clearTimeout(capabilityTimer);
    capabilityTimer = null;
  }
};

export function resetExternalFeedSession () {
  clearExternalFeedTimers();
  resetExternalBoostReconcile();
  externalFeedSession.dispose();
}

export function discardExternalFeedSessionForTests () {
  clearExternalFeedTimers();
  clearDeferredExternalReconnectsForTests();
  externalFeedSession.resetForTests();

  if (visibilityHandler && typeof document !== 'undefined') {
    document.removeEventListener('visibilitychange', visibilityHandler);
  }

  visibilityHandler = null;
  bindExternalFeedVisibility.bound = false;
}

export function receiveExternalFeedChanged (payload) {
  return (dispatch, getState) => {
    const parsed = parseControl(payload);

    if (!parsed.ok) {
      return;
    }

    externalFeedSession.noteControl(parsed);

    if (parsed.reason === 'list_removed') {
      parsed.targets.forEach(target => {
        if (target.type !== 'list') {
          return;
        }

        dispatch({ type: TIMELINE_EXTERNAL_CLEAR_VIEW, timeline: `list:${target.id}` });
        dispatch(clearMixList(target.id));
      });
    }

    externalFeedSession.matchingViews(parsed.targets).forEach(view => {
      dispatch(runExternalReconcile(view.key, view.token));
    });
  };
}

const scheduleCapabilityRetry = (dispatch) => {
  if (capabilityTimer) {
    return;
  }

  capabilityTimer = setTimeout(() => {
    capabilityTimer = null;
    dispatch(refreshExternalFeedCapability());
  }, 2000);
};

export function refreshExternalFeedCapability () {
  return (dispatch, getState) => {
    const client = httpClient(getState);

    if (!client) {
      return Promise.resolve();
    }

    const marker = externalFeedSession.capabilityMarker();

    return client.get('/api/v1/timelines/external_feed_capability').then(response => {
      if (!externalFeedSession.capabilityCurrent(marker)) {
        return;
      }

      const permitted = !!(response && response.data && response.data.permitted === true);
      const previous = permittedNow(getState());

      if (permitted === previous) {
        return;
      }

      externalFeedSession.bumpCapability();
      dispatch({ type: EXTERNAL_FEEDS_PERMITTED, permitted });
      externalFeedSession.openViews().forEach(view => externalFeedSession.invalidate(view.key));
      dispatch(reconcileOpenExternalViews());
    }).catch(error => {
      const status = error && error.response && error.response.status;

      if (status === 429) {
        scheduleCapabilityRetry(dispatch);
      }
    });
  };
}

export function reconcileOpenExternalViews () {
  return (dispatch) => {
    externalFeedSession.openViews().forEach(view => {
      dispatch(runExternalReconcile(view.key, view.token));
    });
  };
}

// A new pass re-reads held ids. Continuation inside one pass does not call this.
export function resumeExternalFeedViews (spec = {}) {
  return (dispatch) => {
    const open = externalFeedSession.openViews();
    const chosen = new Map();

    if (!spec.keys && !spec.targets) {
      open.forEach(view => chosen.set(view.key, view));
    } else {
      if (spec.targets) {
        externalFeedSession.matchingViews(spec.targets).forEach(view => chosen.set(view.key, view));
      }

      (spec.keys || []).forEach(key => {
        const view = open.find(item => item.key === key);

        if (view) {
          chosen.set(view.key, view);
        }
      });
    }

    chosen.forEach(view => {
      externalFeedSession.beginPass(view.key);
      dispatch(runExternalReconcile(view.key, view.token));
    });
  };
}

export function reconcileExternalFeedView (key) {
  return (dispatch) => {
    const view = externalFeedSession.openViews().find(item => item.key === key);

    if (view) {
      dispatch(runExternalReconcile(view.key, view.token));
    }
  };
}

export function noteExternalStatusStream (id) {
  if (id === undefined || id === null || id === '') {
    return;
  }

  externalFeedSession.noteStatus(id);
}

function clearMixList (listId) {
  return (dispatch, getState) => {
    const columns = getState().get('mix_timelines');

    if (!columns) {
      return;
    }

    columns.forEach((column, columnKey) => {
      const mix = findMix(getState(), column.get('mixId'));
      const plain = plainMix(mix);

      if (!plain) {
        return;
      }

      plain.sources.forEach(source => {
        if (source.type !== 'list' || String(source.id) !== String(listId)) {
          return;
        }

        dispatch({
          type: MIX_EXTERNAL_RECONCILE,
          columnKey,
          sourceKey: sourceKey(source),
          sessionId: column.get('sessionId'),
          definitionFingerprint: column.get('definitionFingerprint'),
          clear: true,
        });
      });
    });
  };
}

function runExternalReconcile (key, token) {
  return async (dispatch, getState) => {
    if (!externalFeedSession.claim(key, token)) {
      return;
    }

    let retry = false;

    try {
      retry = await reconcileKey(dispatch, getState, key, token);
    } catch (error) {
      const status = error && error.response && error.response.status;

      if (responsePreservesDisplayed(status)) {
        retry = status === 429;
      }
    } finally {
      const again = externalFeedSession.finish(key, token);

      if (again) {
        dispatch(runExternalReconcile(key, token));
      } else if (retry) {
        scheduleRetry(dispatch, key, token);
      }
    }
  };
}

async function reconcileKey (dispatch, getState, key, token) {
  if (key === 'home') {
    return reconcileTimeline(dispatch, getState, { key, token, timeline: 'home', source: 'home', context: () => ({ visibilities: getHomeVisibilities(getState()) }) });
  }

  if (key.indexOf('list:') === 0) {
    const id = key.slice(5);

    return reconcileTimeline(dispatch, getState, {
      key,
      token,
      timeline: key,
      source: 'list',
      context: () => ({ id }),
      path: `/api/v1/timelines/list/${id}`,
      params: () => ({}),
    });
  }

  if (key.indexOf('mix:') === 0) {
    return reconcileMix(dispatch, getState, key, token);
  }

  return false;
}

function liveSnapshot (getState, key, ids) {
  const state = getState();

  return {
    permitted: permittedNow(state),
    visibilitiesKey: key === 'home' ? getHomeVisibilities(state).join(',') : '',
    statusEpochs: externalFeedSession.statusEpochsFor(ids),
  };
}

const uncheckedIds = (ids, checked) => (ids || []).filter(id => id && !checked.has(String(id)));

const listOf = (value) => {
  if (!value) {
    return [];
  }

  if (typeof value.toArray === 'function') {
    return value.toArray();
  }

  return Array.isArray(value) ? value : [];
};

const freshStatuses = (statuses, marker) => (statuses || []).filter(status => {
  const id = status && status.id;

  return id && !externalFeedSession.statusMovedSince(id, marker);
});

const markIds = (checked, ids) => {
  (ids || []).forEach(id => checked.add(String(id)));
};

const mixConstraints = (getState) => ({
  externalFeedsPermitted: permittedNow(getState()),
});

const responseRequestsRetry = (response) => {
  const status = response && response.status;

  return status === 429 || status === 206;
};

function stillCurrent (getState, snapshot, key) {
  const gate = externalFeedSession.accept(snapshot);

  if (!gate.ok) {
    return null;
  }

  const live = liveSnapshot(getState, key, []);

  if (live.permitted !== snapshot.permitted || live.visibilitiesKey !== snapshot.visibilitiesKey) {
    return null;
  }

  return gate;
}

async function reconcileTimeline (dispatch, getState, spec) {
  const ids = timelineHeldIds(getState(), spec.timeline);
  const context = spec.context();
  const base = liveSnapshot(getState, spec.key, ids);
  const snapshot = externalFeedSession.snapshot(spec.key, spec.token, base);
  const progress = externalFeedSession.progress(spec.key, spec.token);

  if (!snapshot || !progress) {
    return false;
  }

  const client = httpClient(getState);

  if (!client) {
    return false;
  }

  let retry = false;
  const membership = budgetChunks(uncheckedIds(ids, progress.membershipChecked), MEMBERSHIP_BATCH, BATCHES_PER_CYCLE);

  if (membership.remaining) {
    retry = true;
  }

  for (let index = 0; index < membership.chunks.length; index += 1) {
    const chunk = membership.chunks[index];
    const response = await client.post('/api/v1/timelines/membership', {
      version: 1,
      source: spec.source,
      context,
      ids: chunk,
    });

    if (responseRequestsRetry(response)) {
      return true;
    }

    if (responsePreservesDisplayed(response && response.status)) {
      return false;
    }

    const gate = stillCurrent(getState, snapshot, spec.key);
    const current = gate && externalFeedSession.progress(spec.key, spec.token);

    if (!gate || !current) {
      return false;
    }

    const body = response.data || {};

    if (body.outcome !== 'complete' && body.outcome !== 'partial') {
      return false;
    }

    const planned = planMembership({
      rows: body.results,
      movedSince: (id) => externalFeedSession.statusMovedSince(id, snapshot.streamClock),
    });

    if (planned.removeIds.length) {
      dispatch({
        type: TIMELINE_EXTERNAL_RECONCILE,
        timeline: spec.timeline,
        removeIds: planned.removeIds,
        insertIds: [],
      });
    }

    markIds(current.membershipChecked, planned.checkedIds);

    if (planned.staleIds.length) {
      retry = true;
    }
  }

  const bodies = await refreshBodies(dispatch, getState, client, timelineHeldIds(getState(), spec.timeline), snapshot, spec.key, progress);

  if (bodies.stop) {
    return false;
  }

  if (bodies.halt) {
    return true;
  }

  if (bodies.retry) {
    retry = true;
  }

  const history = (spec.source === 'list' || snapshot.permitted)
    ? await fillTimeline(dispatch, getState, client, spec, snapshot, progress)
    : { stop: false, retry: false };

  if (history.stop) {
    return false;
  }

  if (history.retry) {
    retry = true;
  }

  return retry;
}

async function refreshBodies (dispatch, getState, client, ids, snapshot, key, progress) {
  const current = externalFeedSession.progress(key, snapshot.token) || progress;

  if (!current) {
    return { stop: true, retry: false };
  }

  const externalIds = (ids || []).filter(id => getState().getIn(['statuses', id, 'visibility']) === 'external');
  const plan = budgetChunks(uncheckedIds(externalIds, current.bodyChecked), BODY_BATCH, BATCHES_PER_CYCLE);
  let retry = plan.remaining;

  for (let index = 0; index < plan.chunks.length; index += 1) {
    const chunk = plan.chunks[index];
    const response = await client.get('/api/v1/statuses', { params: { id: chunk } });

    if (responseRequestsRetry(response)) {
      return { stop: false, retry: true, halt: true };
    }

    if (responsePreservesDisplayed(response && response.status)) {
      return { stop: false, retry: false };
    }

    const gate = stillCurrent(getState, snapshot, key);
    const live = gate && externalFeedSession.progress(key, snapshot.token);

    if (!gate || !live) {
      return { stop: true, retry: false };
    }

    const statuses = Array.isArray(response.data) ? response.data : [];
    const fresh = freshStatuses(statuses, snapshot.streamClock);
    const stable = chunk.filter(id => !externalFeedSession.statusMovedSince(id, snapshot.streamClock));

    if (fresh.length) {
      dispatch(importFetchedStatuses(fresh));
    }

    markIds(live.bodyChecked, stable);

    if (stable.length !== chunk.length) {
      retry = true;
    }
  }

  return { stop: false, retry };
}

function timelineRanges (state, timeline) {
  const ranges = [{
    side: 'live',
    timeline,
    items: listOf(state.getIn(['timelines', timeline, 'items'])),
  }];
  const split = state.getIn(['timelines', timeline, 'splitTimelineId']);

  if (split) {
    ranges.push({
      side: 'history',
      timeline: split,
      items: listOf(state.getIn(['timelines', split, 'items'])),
    });
  }

  return ranges;
}

async function loadExhaustedTimelineTail (dispatch, getState, client, spec, snapshot, progress, range, pages) {
  if (getState().getIn(['timelines', range.timeline, 'hasMore']) !== false) {
    return { pages, retry: false, stop: false };
  }

  const items = listOf(getState().getIn(['timelines', range.timeline, 'items']));
  const tail = exhaustedTailSegment(items);

  if (!tail) {
    return { pages, retry: false, stop: false };
  }

  const rangeKey = `${range.side}:${tail.key}:exhausted`;
  const saved = progress.history[rangeKey] || { done: false, cursor: tail.oldest };

  if (saved.done) {
    return { pages, retry: false, stop: false };
  }

  if (pages >= HISTORY_PAGES_PER_CYCLE) {
    return { pages, retry: true, stop: false };
  }

  const path = spec.path || '/api/v1/timelines/home';
  const params = spec.params ? spec.params() : { visibilities: getHomeVisibilities(getState()) };
  const response = await client.get(path, { params: { ...params, limit: HISTORY_PAGE_SIZE, max_id: saved.cursor } });

  pages += 1;

  if (!response || response.status === 206 || responsePreservesDisplayed(response.status)) {
    return { pages, retry: !response || response.status === 429 || response.status === 206, stop: false };
  }

  const gate = stillCurrent(getState, snapshot, spec.key);
  const live = gate && externalFeedSession.progress(spec.key, spec.token);

  if (!gate || !live) {
    return { pages, retry: false, stop: true };
  }

  const statuses = Array.isArray(response.data) ? response.data : (response.data && response.data.statuses) || [];
  const currentItems = listOf(getState().getIn(['timelines', range.timeline, 'items']));
  const gated = freshStatuses(statuses, snapshot.streamClock);
  const placed = placeReconcileIds(currentItems, gated.map(status => status.id), { extendExhaustedTail: true });
  const inserted = new Set(placed.inserted);
  const fresh = gated.filter(status => inserted.has(String(status.id)));

  if (fresh.length) {
    dispatch(importFetchedStatuses(fresh));
    dispatch({
      type: TIMELINE_EXTERNAL_RECONCILE,
      timeline: range.timeline,
      removeIds: [],
      insertIds: placed.inserted,
      extendExhaustedTail: true,
    });
  }

  const cursor = nextExhaustedPage(statuses, HISTORY_PAGE_SIZE);

  live.history[rangeKey] = !cursor.done && cursor.cursor === saved.cursor ? { done: true, cursor: null } : cursor;

  return { pages, retry: !live.history[rangeKey].done, stop: false };
}

async function fillTimeline (dispatch, getState, client, spec, snapshot, progress) {
  const path = spec.path || '/api/v1/timelines/home';
  const params = spec.params ? spec.params() : { visibilities: getHomeVisibilities(getState()) };
  const ranges = timelineRanges(getState(), spec.timeline);
  let pages = 0;
  let retry = false;

  for (let rangeIndex = 0; rangeIndex < ranges.length; rangeIndex += 1) {
    const range = ranges[rangeIndex];
    const tailPage = await loadExhaustedTimelineTail(dispatch, getState, client, spec, snapshot, progress, range, pages);

    pages = tailPage.pages;

    if (tailPage.stop) {
      return { stop: true, retry: false };
    }

    if (tailPage.retry) {
      retry = true;
    }

    const segments = loadedRanges(range.items);

    for (let segmentIndex = 0; segmentIndex < segments.length; segmentIndex += 1) {
      const segment = segments[segmentIndex];

      if (segment.skip) {
        continue;
      }

      const rangeKey = `${range.side}:${segment.key}`;
      const saved = progress.history[rangeKey] || { done: false, cursor: segment.newest };

      if (saved.done) {
        continue;
      }

      if (pages >= HISTORY_PAGES_PER_CYCLE) {
        retry = true;
        continue;
      }

      const query = { ...params, limit: HISTORY_PAGE_SIZE };

      if (saved.cursor) {
        query.max_id = saved.cursor;
      }

      const response = await client.get(path, { params: query });

      pages += 1;

      if (!response || response.status === 206 || responsePreservesDisplayed(response.status)) {
        return { stop: false, retry: !response || response.status === 429 || response.status === 206 };
      }

      const gate = stillCurrent(getState, snapshot, spec.key);
      const live = gate && externalFeedSession.progress(spec.key, spec.token);

      if (!gate || !live) {
        return { stop: true, retry: false };
      }

      const statuses = Array.isArray(response.data) ? response.data : (response.data && response.data.statuses) || [];
      const currentItems = listOf(getState().getIn(['timelines', range.timeline, 'items']));
      const gated = freshStatuses(statuses, snapshot.streamClock);
      const placed = placeReconcileIds(currentItems, gated.map(status => status.id), { seed: segment.empty });
      const inserted = new Set(placed.inserted);
      const fresh = gated.filter(status => inserted.has(String(status.id)));

      if (fresh.length) {
        dispatch(importFetchedStatuses(fresh));
        dispatch({
          type: TIMELINE_EXTERNAL_RECONCILE,
          timeline: range.timeline,
          removeIds: [],
          insertIds: placed.inserted,
          seed: segment.empty,
        });
      }

      const cursor = nextHistoryCursor(segment, statuses, HISTORY_PAGE_SIZE);

      if (!cursor.done && cursor.cursor === saved.cursor) {
        live.history[rangeKey] = { done: true, cursor: null };
      } else {
        live.history[rangeKey] = cursor;
      }

      if (!live.history[rangeKey].done) {
        retry = true;
      }
    }
  }

  return { stop: false, retry };
}

const mixSourceTag = (sourceKeyValue, id) => `${sourceKeyValue}\n${id}`;

function mixRanges (state, columnKey, keyForSource) {
  const ranges = [{
    side: 'live',
    items: listOf(state.getIn(['mix_timelines', columnKey, 'sources', keyForSource, 'ids'])),
  }];
  const history = state.getIn(['mix_timelines', columnKey, 'split', 'history', 'sources', keyForSource, 'ids']);

  if (history) {
    ranges.push({ side: 'history', items: listOf(history) });
  }

  return ranges;
}

function mixColumnCurrent (getState, columnKey, snapshot) {
  const columnNow = getState().getIn(['mix_timelines', columnKey]);

  if (!columnNow || columnNow.get('sessionId') !== snapshot.sessionId || columnNow.get('definitionFingerprint') !== snapshot.definitionFingerprint) {
    return false;
  }

  return externalFeedSession.accept(snapshot).ok;
}

async function reconcileMix (dispatch, getState, key, token) {
  const columnKey = key.slice(4);
  const column = getState().getIn(['mix_timelines', columnKey]);

  if (!column) {
    return false;
  }

  const mix = findMix(getState(), column.get('mixId'));
  const plain = plainMix(mix);
  const client = httpClient(getState);
  const progress = externalFeedSession.progress(key, token);

  if (!plain || !client || !progress) {
    return false;
  }

  let retry = false;
  let pages = 0;

  for (let index = 0; index < plain.sources.length; index += 1) {
    const source = plain.sources[index];

    if (source.type !== 'home' && source.type !== 'list') {
      continue;
    }

    const request = resolveRequest(source, null, mixConstraints(getState));

    if (!request.ok) {
      continue;
    }

    const keyForSource = sourceKey(source);
    const ids = mixHeldIds(getState(), columnKey, keyForSource);
    const asksExternal = source.type === 'list' || (request.params.visibilities || []).indexOf('external') !== -1;
    const context = source.type === 'home'
      ? { visibilities: request.params.visibilities }
      : { id: String(source.id) };
    const pendingMembership = uncheckedIds(ids, progress.membershipChecked).filter(id => !progress.membershipChecked.has(mixSourceTag(keyForSource, id)));
    const snapshot = externalFeedSession.snapshot(key, token, {
      permitted: permittedNow(getState()) && asksExternal,
      sessionId: column.get('sessionId'),
      definitionFingerprint: column.get('definitionFingerprint'),
      statusEpochs: externalFeedSession.statusEpochsFor(ids),
    });

    if (!snapshot) {
      return false;
    }

    const membership = budgetChunks(pendingMembership, MEMBERSHIP_BATCH, BATCHES_PER_CYCLE);

    if (membership.remaining) {
      retry = true;
    }

    for (let chunkIndex = 0; chunkIndex < membership.chunks.length; chunkIndex += 1) {
      const chunk = membership.chunks[chunkIndex];
      const response = await client.post('/api/v1/timelines/membership', {
        version: 1,
        source: source.type,
        context,
        ids: chunk,
      });

      if (responseRequestsRetry(response)) {
        return true;
      }

      if (responsePreservesDisplayed(response && response.status)) {
        return false;
      }

      if (!mixColumnCurrent(getState, columnKey, snapshot)) {
        return false;
      }

      const live = externalFeedSession.progress(key, token);

      if (!live) {
        return false;
      }

      const body = response.data || {};

      if (body.outcome !== 'complete' && body.outcome !== 'partial') {
        return false;
      }

      const planned = planMembership({
        rows: body.results,
        movedSince: (id) => externalFeedSession.statusMovedSince(id, snapshot.streamClock),
      });

      if (planned.staleIds.length) {
        retry = true;
      }

      markIds(live.membershipChecked, planned.checkedIds.map(id => mixSourceTag(keyForSource, id)));

      if (planned.removeIds.length) {
        dispatch({
          type: MIX_EXTERNAL_RECONCILE,
          columnKey,
          sourceKey: keyForSource,
          sessionId: snapshot.sessionId,
          definitionFingerprint: snapshot.definitionFingerprint,
          removeIds: planned.removeIds,
        });
      }
    }

    const bodies = await refreshBodies(dispatch, getState, client, mixHeldIds(getState(), columnKey, keyForSource), snapshot, key, progress);

    if (bodies.stop) {
      return false;
    }

    if (bodies.halt) {
      return true;
    }

    if (bodies.retry) {
      retry = true;
    }

    if (asksExternal) {
      const filled = await fillMixSource(dispatch, getState, client, columnKey, source, keyForSource, snapshot, progress, () => {
        pages += 1;
        return pages <= HISTORY_PAGES_PER_CYCLE;
      });

      if (filled.stop) {
        return false;
      }

      if (filled.retry) {
        retry = true;
      }
    }
  }

  return retry;
}

async function loadExhaustedMixTail (dispatch, getState, client, columnKey, source, keyForSource, snapshot, progress, takePage) {
  const sourceState = getState().getIn(['mix_timelines', columnKey, 'sources', keyForSource]);

  if (!sourceState || sourceState.get('hasMore') !== false || sourceState.get('gap') || sourceState.get('partial')) {
    return { retry: false, stop: false };
  }

  const items = listOf(sourceState.get('ids'));
  const tail = exhaustedTailSegment(items);

  if (!tail) {
    return { retry: false, stop: false };
  }

  const rangeKey = `${keyForSource}:live:${tail.key}:exhausted`;
  const saved = progress.history[rangeKey] || { done: false, cursor: tail.oldest };

  if (saved.done) {
    return { retry: false, stop: false };
  }

  if (!takePage()) {
    return { retry: true, stop: false };
  }

  const request = resolveRequest(source, saved.cursor, mixConstraints(getState));

  if (!request.ok) {
    return { retry: false, stop: false };
  }

  const response = await client.get(request.path, { params: { ...request.params, limit: HISTORY_PAGE_SIZE } });

  if (!response || response.status === 206 || responsePreservesDisplayed(response.status)) {
    return { retry: !response || response.status === 429 || response.status === 206, stop: false };
  }

  if (!mixColumnCurrent(getState, columnKey, snapshot)) {
    return { retry: false, stop: true };
  }

  const live = externalFeedSession.progress(snapshot.key, snapshot.token);

  if (!live) {
    return { retry: false, stop: true };
  }

  const page = normalizePage({ status: response.status, data: response.data, path: request.path });

  if (!page.ok) {
    return { retry: false, stop: false };
  }

  const flags = visibilityConstraints(mixConstraints(getState));
  const me = getState().getIn(['meta', 'me']);
  const movedSince = (id) => externalFeedSession.statusMovedSince(id, snapshot.streamClock);
  const visible = page.statuses.filter(status => classifyStreamStatus(source, status, {
    me,
    constraints: flags,
    delivered: source.type === 'list',
  }) === 'accept');
  const gated = protectStatusBodies(visible, movedSince);
  const currentItems = listOf(getState().getIn(['mix_timelines', columnKey, 'sources', keyForSource, 'ids']));
  const placed = placeReconcileIds(currentItems, gated.map(status => status.id), { extendExhaustedTail: true });
  const inserted = new Set(placed.inserted);
  const fresh = gated.filter(status => inserted.has(String(status.id)));

  if (fresh.length) {
    dispatch(importFetchedStatuses(fresh));
    dispatch({
      type: MIX_EXTERNAL_RECONCILE,
      columnKey,
      sourceKey: keyForSource,
      sessionId: snapshot.sessionId,
      definitionFingerprint: snapshot.definitionFingerprint,
      removeIds: [],
      insertIds: placed.inserted,
      range: { side: 'live' },
    });
  }

  const cursor = nextExhaustedPage(page.statuses, HISTORY_PAGE_SIZE);

  live.history[rangeKey] = !cursor.done && cursor.cursor === saved.cursor ? { done: true, cursor: null } : cursor;

  return { retry: !live.history[rangeKey].done, stop: false };
}

async function fillMixSource (dispatch, getState, client, columnKey, source, keyForSource, snapshot, progress, takePage) {
  const ranges = mixRanges(getState(), columnKey, keyForSource);
  let retry = false;

  const tailPage = await loadExhaustedMixTail(dispatch, getState, client, columnKey, source, keyForSource, snapshot, progress, takePage);

  if (tailPage.stop) {
    return { stop: true, retry: false };
  }

  if (tailPage.retry) {
    retry = true;
  }

  for (let rangeIndex = 0; rangeIndex < ranges.length; rangeIndex += 1) {
    const range = ranges[rangeIndex];
    const segments = loadedRanges(range.items);

    for (let segmentIndex = 0; segmentIndex < segments.length; segmentIndex += 1) {
      const segment = segments[segmentIndex];

      if (segment.skip) {
        continue;
      }

      const rangeKey = `${keyForSource}:${range.side}:${segment.key}`;
      const saved = progress.history[rangeKey] || { done: false, cursor: segment.newest };

      if (saved.done) {
        continue;
      }

      if (!takePage()) {
        retry = true;
        continue;
      }

      const request = resolveRequest(source, saved.cursor, mixConstraints(getState));

      if (!request.ok) {
        return { stop: false, retry: false };
      }

      const splitId = range.side === 'history'
        ? getState().getIn(['mix_timelines', columnKey, 'split', 'id'])
        : null;
      const response = await client.get(request.path, { params: { ...request.params, limit: HISTORY_PAGE_SIZE } });

      if (!response || response.status === 206 || responsePreservesDisplayed(response.status)) {
        return { stop: false, retry: !response || response.status === 429 || response.status === 206 };
      }

      if (!mixColumnCurrent(getState, columnKey, snapshot)) {
        return { stop: true, retry: false };
      }

      const live = externalFeedSession.progress(snapshot.key, snapshot.token);

      if (!live) {
        return { stop: true, retry: false };
      }

      const page = normalizePage({
        status: response.status,
        data: response.data,
        path: request.path,
      });

      if (!page.ok) {
        continue;
      }

      const flags = visibilityConstraints(mixConstraints(getState));
      const me = getState().getIn(['meta', 'me']);
      const movedSince = (id) => externalFeedSession.statusMovedSince(id, snapshot.streamClock);
      const visible = page.statuses.filter(status => classifyStreamStatus(source, status, {
        me,
        constraints: flags,
        delivered: source.type === 'list',
      }) === 'accept');
      const gated = protectStatusBodies(visible, movedSince);
      const references = protectStatusBodies(page.referencedStatuses, movedSince);
      const currentItems = listOf(getState().getIn(['mix_timelines', columnKey, 'sources', keyForSource, 'ids']));
      const historyItems = listOf(getState().getIn(['mix_timelines', columnKey, 'split', 'history', 'sources', keyForSource, 'ids']));
      const items = range.side === 'history' ? historyItems : currentItems;
      const sourceState = getState().getIn(['mix_timelines', columnKey, 'sources', keyForSource]);
      const tail = exhaustedTailSegment(items);
      const exhausted = !!(sourceState && sourceState.get('hasMore') === false && !sourceState.get('gap') && !sourceState.get('partial') && tail && String(tail.oldest) === String(segment.oldest));
      const placed = placeReconcileIds(items, gated.map(status => status.id), { seed: segment.empty, extendExhaustedTail: exhausted });
      const inserted = new Set(placed.inserted);
      const fresh = gated.filter(status => inserted.has(String(status.id)));
      const bodies = references.concat(fresh);

      if (page.accounts.length) {
        dispatch(importFetchedAccounts(page.accounts));
      }

      if (page.relationships.length) {
        dispatch(fetchRelationshipsSuccess(page.relationships));
      }

      if (page.filters.length) {
        dispatch(importFilters(page.filters));
      }

      if (bodies.length) {
        const previous = previousStatusesForImport(getState().get('statuses'), bodies);

        dispatch(importFetchedStatuses(statusesForSharedImport(bodies, previous)));
      }

      if (fresh.length) {
        const filterResults = {};

        fresh.forEach(status => {
          filterResults[status.id] = page.filterResults[status.id] || [];
        });

        dispatch({
          type: MIX_EXTERNAL_RECONCILE,
          columnKey,
          sourceKey: keyForSource,
          sessionId: snapshot.sessionId,
          definitionFingerprint: snapshot.definitionFingerprint,
          removeIds: [],
          insertIds: placed.inserted,
          seed: segment.empty,
          range: { side: range.side, splitId },
          filterResults,
        });
      }

      const cursor = nextHistoryCursor(segment, page.statuses, HISTORY_PAGE_SIZE);

      live.history[rangeKey] = !cursor.done && cursor.cursor === saved.cursor ? { done: true, cursor: null } : cursor;

      if (!live.history[rangeKey].done) {
        retry = true;
      }
    }
  }

  return { stop: false, retry };
}

export function bindExternalFeedVisibility () {
  return (dispatch) => {
    if (typeof document === 'undefined' || bindExternalFeedVisibility.bound) {
      return;
    }

    bindExternalFeedVisibility.bound = true;
    visibilityHandler = () => {
      if (document.visibilityState === 'visible') {
        dispatch(refreshExternalFeedCapability());
        dispatch(reconcileHeldExternalBoosts({ begin: true }));
        dispatch(resumeExternalFeedViews());
      }
    };
    document.addEventListener('visibilitychange', visibilityHandler);
  };
}
