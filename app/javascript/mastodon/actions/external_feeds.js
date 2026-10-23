import api from '../api';
import { importFetchedStatuses } from './importer';
import { getHomeVisibilities } from '../selectors';
import {
  TIMELINE_EXTERNAL_CLEAR_VIEW,
  TIMELINE_EXTERNAL_RECONCILE,
} from './timelines';
import { MIX_EXTERNAL_RECONCILE } from './mix_timelines';
import { plainMix } from '../mix/definition';
import { normalizeSource, sourceKey } from '../mix/source';
import { externalFeedSession } from '../external_feeds/session';
import {
  BATCHES_PER_CYCLE,
  BODY_BATCH,
  HISTORY_PAGES_PER_CYCLE,
  MEMBERSHIP_BATCH,
  chunkIds,
  parseControl,
  planMembership,
  responsePreservesDisplayed,
  statusesInsideLoadedRange,
} from '../external_feeds/reconcile';

export const EXTERNAL_FEEDS_PERMITTED = 'EXTERNAL_FEEDS_PERMITTED';

const retries = new Map();
let capabilityTimer = null;

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
  externalFeedSession.dispose();
}

export function discardExternalFeedSessionForTests () {
  clearExternalFeedTimers();
  externalFeedSession.resetForTests();
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

  if (!snapshot) {
    return false;
  }

  const client = httpClient(getState);

  if (!client || !ids.length) {
    if (client && snapshot.permitted && spec.timeline === 'home') {
      await fillTimeline(dispatch, getState, client, spec, snapshot);
    }

    return false;
  }

  const chunks = chunkIds(ids, MEMBERSHIP_BATCH).slice(0, BATCHES_PER_CYCLE);
  let retry = chunks.length < chunkIds(ids, MEMBERSHIP_BATCH).length;

  for (let index = 0; index < chunks.length; index += 1) {
    const chunk = chunks[index];
    const response = await client.post('/api/v1/timelines/membership', {
      version: 1,
      source: spec.source,
      context,
      ids: chunk,
    });

    if (responsePreservesDisplayed(response && response.status)) {
      return !!(response && response.status === 429);
    }

    const gate = stillCurrent(getState, snapshot, spec.key);

    if (!gate) {
      return false;
    }

    const body = response.data || {};
    const planned = planMembership({
      rows: body.results,
      requestedEpochs: snapshot.statusEpochs,
      currentEpochs: externalFeedSession.statusEpochsFor(chunk),
    });

    if (planned.removeIds.length) {
      dispatch({
        type: TIMELINE_EXTERNAL_RECONCILE,
        timeline: spec.timeline,
        removeIds: planned.removeIds,
        insertIds: [],
      });
    }

    if (planned.staleIds.length) {
      retry = true;
    }

    if (body.outcome !== 'complete' && body.outcome !== 'partial') {
      return false;
    }
  }

  await refreshBodies(dispatch, getState, client, timelineHeldIds(getState(), spec.timeline), snapshot, spec.key);
  if (snapshot.permitted) {
    await fillTimeline(dispatch, getState, client, spec, snapshot);
  }

  return retry;
}

async function refreshBodies (dispatch, getState, client, ids, snapshot, key) {
  const externalIds = ids.filter(id => getState().getIn(['statuses', id, 'visibility']) === 'external');
  const chunks = chunkIds(externalIds, BODY_BATCH).slice(0, BATCHES_PER_CYCLE);

  for (let index = 0; index < chunks.length; index += 1) {
    const chunk = chunks[index];
    const response = await client.get('/api/v1/statuses', { params: { id: chunk } });

    if (responsePreservesDisplayed(response && response.status)) {
      return;
    }

    const gate = stillCurrent(getState, snapshot, key);

    if (!gate) {
      return;
    }

    const statuses = Array.isArray(response.data) ? response.data : [];
    const fresh = statuses.filter(status => {
      const id = status && String(status.id);
      const requested = snapshot.statusEpochs[id] || 0;

      return externalFeedSession.statusEpoch(id) === requested;
    });

    if (fresh.length) {
      dispatch(importFetchedStatuses(fresh));
    }
  }
}

async function fillTimeline (dispatch, getState, client, spec, snapshot) {
  const items = (getState().getIn(['timelines', spec.timeline, 'items']) || []).toArray ? getState().getIn(['timelines', spec.timeline, 'items']).toArray() : [];

  if (items.filter(Boolean).length < 2) {
    return;
  }

  const path = spec.path || '/api/v1/timelines/home';
  const params = spec.params ? spec.params() : { visibilities: getHomeVisibilities(getState()) };
  let maxId = items.find(id => id);

  for (let page = 0; page < HISTORY_PAGES_PER_CYCLE && maxId; page += 1) {
    const response = await client.get(path, { params: { ...params, max_id: maxId, limit: 40 } });

    if (!response || response.status === 206 || responsePreservesDisplayed(response.status)) {
      return;
    }

    const gate = stillCurrent(getState, snapshot, spec.key);

    if (!gate) {
      return;
    }

    const statuses = Array.isArray(response.data) ? response.data : (response.data && response.data.statuses) || [];
    const currentItems = getState().getIn(['timelines', spec.timeline, 'items']).toArray();
    const chosen = statusesInsideLoadedRange(currentItems, statuses);

    if (chosen.statuses.length) {
      const fresh = chosen.statuses.filter(status => externalFeedSession.statusEpoch(status.id) === (snapshot.statusEpochs[String(status.id)] || 0));

      if (fresh.length) {
        dispatch(importFetchedStatuses(fresh));
        dispatch({
          type: TIMELINE_EXTERNAL_RECONCILE,
          timeline: spec.timeline,
          removeIds: [],
          insertIds: fresh.map(status => String(status.id)),
        });
      }
    }

    if (statuses.length < 40) {
      return;
    }

    const oldest = statuses[statuses.length - 1];

    maxId = oldest && oldest.id;
  }
}

async function reconcileMix (dispatch, getState, key, token) {
  const columnKey = key.slice(4);
  const column = getState().getIn(['mix_timelines', columnKey]);

  if (!column) {
    return false;
  }

  const mix = findMix(getState(), column.get('mixId'));
  const plain = plainMix(mix);

  if (!plain) {
    return false;
  }

  const client = httpClient(getState);
  let retry = false;

  if (!client) {
    return false;
  }

  for (let index = 0; index < plain.sources.length; index += 1) {
    const source = plain.sources[index];

    if (source.type !== 'home' && source.type !== 'list') {
      continue;
    }

    const keyForSource = sourceKey(source);
    const ids = mixHeldIds(getState(), columnKey, keyForSource);
    const includeExternal = source.type === 'list' || (source.params && source.params.shows && source.params.shows.external === true);
    const context = source.type === 'home'
      ? { visibilities: homeVisibilitiesForMix(source, permittedNow(getState())) }
      : { id: String(source.id) };
    const snapshot = externalFeedSession.snapshot(key, token, {
      permitted: permittedNow(getState()) && includeExternal,
      sessionId: column.get('sessionId'),
      definitionFingerprint: column.get('definitionFingerprint'),
      statusEpochs: externalFeedSession.statusEpochsFor(ids),
    });

    if (!snapshot) {
      return false;
    }

    const chunks = chunkIds(ids, MEMBERSHIP_BATCH).slice(0, BATCHES_PER_CYCLE);

    if (chunks.length < chunkIds(ids, MEMBERSHIP_BATCH).length) {
      retry = true;
    }

    for (let chunkIndex = 0; chunkIndex < chunks.length; chunkIndex += 1) {
      const chunk = chunks[chunkIndex];
      const response = await client.post('/api/v1/timelines/membership', {
        version: 1,
        source: source.type,
        context,
        ids: chunk,
      });

      if (responsePreservesDisplayed(response && response.status)) {
        return !!(response && response.status === 429);
      }

      const columnNow = getState().getIn(['mix_timelines', columnKey]);

      if (!columnNow || columnNow.get('sessionId') !== snapshot.sessionId || columnNow.get('definitionFingerprint') !== snapshot.definitionFingerprint) {
        return false;
      }

      if (!externalFeedSession.accept(snapshot).ok) {
        return false;
      }

      const planned = planMembership({
        rows: (response.data || {}).results,
        requestedEpochs: snapshot.statusEpochs,
        currentEpochs: externalFeedSession.statusEpochsFor(chunk),
      });

      if (planned.staleIds.length) {
        retry = true;
      }

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

    if (includeExternal && permittedNow(getState())) {
      await fillMixSource(dispatch, getState, client, columnKey, source, keyForSource, snapshot);
    }
  }

  return retry;
}

function homeVisibilitiesForMix (source, permitted) {
  const normalized = normalizeSource(source);
  const shows = (normalized.ok && normalized.source.params && normalized.source.params.shows) || {};
  const keys = ['public', 'unlisted', 'private', 'limited', 'direct', 'personal'];
  const list = keys.filter(name => shows[name] !== false);

  if (permitted && shows.external === true) {
    list.push('external');
  }

  return list;
}

async function fillMixSource (dispatch, getState, client, columnKey, source, keyForSource, snapshot) {
  const items = mixHeldIds(getState(), columnKey, keyForSource);

  if (items.length < 2) {
    return;
  }

  const path = source.type === 'list' ? `/api/v1/timelines/list/${source.id}` : '/api/v1/timelines/home';
  const params = source.type === 'home'
    ? { visibilities: homeVisibilitiesForMix(source, true) }
    : {};
  let maxId = items[0];
  const response = await client.get(path, { params: { ...params, max_id: maxId, limit: 40 } });

  if (!response || response.status === 206 || responsePreservesDisplayed(response.status)) {
    return;
  }

  const columnNow = getState().getIn(['mix_timelines', columnKey]);

  if (!columnNow || columnNow.get('sessionId') !== snapshot.sessionId || !externalFeedSession.accept(snapshot).ok) {
    return;
  }

  const statuses = Array.isArray(response.data) ? response.data : (response.data && response.data.statuses) || [];
  const chosen = statusesInsideLoadedRange(items, statuses);

  if (!chosen.statuses.length) {
    return;
  }

  dispatch(importFetchedStatuses(chosen.statuses));
  dispatch({
    type: MIX_EXTERNAL_RECONCILE,
    columnKey,
    sourceKey: keyForSource,
    sessionId: snapshot.sessionId,
    definitionFingerprint: snapshot.definitionFingerprint,
    removeIds: [],
    insertIds: chosen.inserted,
  });
}

export function bindExternalFeedVisibility () {
  return (dispatch) => {
    if (typeof document === 'undefined' || bindExternalFeedVisibility.bound) {
      return;
    }

    bindExternalFeedVisibility.bound = true;
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        dispatch(refreshExternalFeedCapability());
        dispatch(reconcileOpenExternalViews());
      }
    });
  };
}
