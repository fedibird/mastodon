import api from 'mastodon/api';
import compareId from 'mastodon/compare_id';
import { importFetchedAccounts, importFetchedStatuses } from './importer';
import { NOTIFICATIONS_FEED_MERGE, notificationExcludeTypes } from './notifications';
import { submitMarkers } from './markers';
import { fetchRelationships } from './accounts';
import {
  appliedEmojiMuteRevision,
  currentEmojiMutes,
  emojiMuteNotificationFetchEpoch,
  emojiMuteDocumentReady,
  emojiMuteAuthorizationFailure,
  blockEmojiMuteAuthorization,
  emojiReactionEventsAccepted,
  loadEmojiMutes,
  noteEmojiMutesChanged,
  observedEmojiMuteRevision,
  beginEmojiMuteEnabledFetch,
  applyEmojiMuteDisabledDocument,
  ignoreEmojiMutesForThisView,
  clearEmojiMuteTemporaryIgnore,
  saveEmojiMuteEnabled,
  emojiMuteTemporarilyIgnored,
  invalidateEmojiMuteNotificationFetches,
  abandonEmojiMutePreferenceConfirmation,
  beginEmojiMutePreferenceConfirmation,
  beginEmojiMutePreferenceRead,
  emojiMutePreferenceReadable,
  emojiMutePreferenceConfirmationCurrent,
  emojiMutePreferenceReadCurrent,
  endEmojiMutePreferenceConfirmation,
  emojiMutePreferenceGeneration,
  emojiMuteRequestVersion,
  notePreferenceRevision,
  preferenceRevisionStale,
  loadEmojiMutePreference,
} from '../features/emoji/emoji_mute_store';
import { currentEmojiMuteBoot, noteEmojiMutePreferenceConfirming } from '../features/emoji/emoji_mute_availability';
import { hideReactionSignature, hideSignatureGrew, hideSignatureShrunk, revisionStale } from '../features/emoji/emoji_mute_projection';
import { classifyEmojiMuteFetchError } from '../features/emoji/emoji_mute_fetch_error';
import { emojiMuteBypassEnabled } from '../features/emoji/emoji_mute_boot_bypass';

export { classifyEmojiMuteFetchError };

export const EMOJI_MUTES_IMPORT = 'EMOJI_MUTES_IMPORT';
export const EMOJI_MUTES_REVISION = 'EMOJI_MUTES_REVISION';
export const EMOJI_MUTES_APPLY = 'EMOJI_MUTES_APPLY';
export const EMOJI_MUTES_LOAD = 'EMOJI_MUTES_LOAD';
export const EMOJI_MUTES_FAIL = 'EMOJI_MUTES_FAIL';
export const EMOJI_MUTES_RESET = 'EMOJI_MUTES_RESET';
export const EMOJI_MUTES_DISABLE = 'EMOJI_MUTES_DISABLE';
export const EMOJI_MUTES_ENABLE = 'EMOJI_MUTES_ENABLE';
export const EMOJI_MUTES_IGNORE = 'EMOJI_MUTES_IGNORE';
export const EMOJI_MUTES_CONFIRM = 'EMOJI_MUTES_CONFIRM';
// The newest sync finished without a new document. Subscribers can release
// the retry control. This must not mark the rules ready or reveal emoji.
export const EMOJI_MUTES_SYNC_SETTLED = 'EMOJI_MUTES_SYNC_SETTLED';

export function enableEmojiMuteLoading() {
  return dispatch => {
    cancelInFlightEmojiMuteRefresh();
    beginEmojiMuteEnabledFetch();
    dispatch({ type: EMOJI_MUTES_ENABLE });
  };
}

function cancelInFlightEmojiMuteRefresh() {
  surfaceGeneration += 1;
  invalidateEmojiMuteNotificationFetches();
  restoreQueue = [];
  if (restoreTimer !== null) {
    clearTimeout(restoreTimer);
    restoreTimer = null;
  }
}

function revealEmojiMuteEffects(previousSignature) {
  return (dispatch, getState) => {
    cancelInFlightEmojiMuteRefresh();
    const hideShrunk = hideSignatureShrunk(previousSignature, hideReactionSignature([]));

    dispatch({
      type: EMOJI_MUTES_APPLY,
      mutes: [],
      revision: appliedEmojiMuteRevision() || '0',
      sameDocument: false,
      hideShrunk,
      recovered: true,
    });

    return refreshEmojiMuteSurfaces({
      restoreStatuses: hideShrunk,
      restoreWithheld: true,
    })(dispatch, getState);
  };
}

export function disableEmojiMuteFeature() {
  return dispatch => {
    const previousSignature = hideReactionSignature(currentEmojiMutes());

    return saveEmojiMuteEnabled(false).then(data => {
      if (data && data.applied === true && data.enabled === true && !emojiMuteDocumentReady()) {
        dispatch({ type: EMOJI_MUTES_ENABLE });
        return dispatch(syncEmojiMutes({ verify: true })).then(() => data);
      }

      if (!data || data.applied === false || data.enabled !== false) {
        return data;
      }

      dispatch({ type: EMOJI_MUTES_DISABLE });
      dispatch(revealEmojiMuteEffects(previousSignature));
      return data;
    });
  };
}

function applyAuthoritativeEmojiMutePreference(enabled, explicit) {
  return dispatch => {
    if (enabled === true) {
      if (currentEmojiMuteBoot().availability === 'enabled') {
        if (emojiMuteDocumentReady()) {
          return Promise.resolve(null);
        }

        // The list that was already in flight can be an older OFF snapshot.
        // A forced GET does not join it, and does not reuse the bootstrap promise.
        cancelInFlightEmojiMuteRefresh();
        return dispatch(syncEmojiMutes({ verify: true }));
      }

      cancelInFlightEmojiMuteRefresh();
      beginEmojiMuteEnabledFetch();
      dispatch({ type: EMOJI_MUTES_ENABLE });
      return dispatch(syncEmojiMutes());
    }

    if (enabled === false) {
      const boot = currentEmojiMuteBoot();
      const explicitOff = explicit === true;

      if (boot.availability === 'disabled' && boot.explicit === explicitOff) {
        return Promise.resolve(null);
      }

      const previousSignature = hideReactionSignature(currentEmojiMutes());
      const wasDisabled = boot.availability === 'disabled';
      applyEmojiMuteDisabledDocument(explicitOff);
      dispatch({ type: EMOJI_MUTES_DISABLE });

      if (wasDisabled) {
        return Promise.resolve(null);
      }

      return dispatch(revealEmojiMuteEffects(previousSignature));
    }

    return Promise.resolve(null);
  };
}

// The stream payload is only a notice that the preference changed. A slow
// false event must not win over a newer read of the saved row.
export function applyRemoteEmojiMutePreference(options = {}) {
  return dispatch => {
    const generation = options.generation === undefined ? beginEmojiMutePreferenceRead() : options.generation;

    const failConfirmation = error => {
      if (!emojiMutePreferenceReadCurrent(generation) || !abandonEmojiMutePreferenceConfirmation()) {
        return null;
      }

      dispatch({
        type: EMOJI_MUTES_FAIL,
        failure: classifyEmojiMuteFetchError(error),
      });
      return null;
    };

    return loadEmojiMutePreference().then(data => {
      if (!emojiMutePreferenceReadCurrent(generation)) {
        return null;
      }

      if (!emojiMutePreferenceReadable(data)) {
        return failConfirmation(new Error('Emoji mute preference was not readable'));
      }

      if (preferenceRevisionStale(data.preference_revision)) {
        return null;
      }

      notePreferenceRevision(data.preference_revision);
      return dispatch(applyAuthoritativeEmojiMutePreference(data.enabled, data.explicit === true));
    }).catch(error => failConfirmation(error));
  };
}

export function ignoreEmojiMutesThisView() {
  return dispatch => {
    const previousSignature = hideReactionSignature(currentEmojiMutes());
    ignoreEmojiMutesForThisView();
    dispatch({ type: EMOJI_MUTES_IGNORE });
    return dispatch(revealEmojiMuteEffects(previousSignature));
  };
}

export function bootStandaloneEmojiMutes() {
  return dispatch => {
    if (!currentEmojiMuteBoot().fetch) {
      return Promise.resolve(null);
    }

    return dispatch(retryEmojiMuteLoad({ bootstrap: true })).catch(() => null);
  };
}

export function retryEmojiMuteLoad(options = {}) {
  return (dispatch, getState) => {
    const wasIgnored = emojiMuteTemporarilyIgnored();

    clearEmojiMuteTemporaryIgnore();

    if (currentEmojiMuteBoot().availability === 'disabled') {
      return dispatch(syncEmojiMutes({ bootstrap: options.bootstrap === true }));
    }

    const phase = getState().getIn(['emojiMutes', 'phase']);
    const applied = getState().getIn(['emojiMutes', 'appliedRevision']);

    if (wasIgnored || phase !== 'ready' || applied === null) {
      dispatch({ type: EMOJI_MUTES_ENABLE });
    }

    return dispatch(syncEmojiMutes({ bootstrap: options.bootstrap === true }));
  };
}

export function importEmojiMutes(revision, rules) {
  return {
    type: EMOJI_MUTES_IMPORT,
    revision: revision === null || revision === undefined ? null : String(revision),
    rules: rules || [],
  };
}

export function importEmojiMutesRevision(revision) {
  return {
    type: EMOJI_MUTES_REVISION,
    revision: revision === null || revision === undefined ? null : String(revision),
  };
}

// The status index rejects more than DEFAULT_STATUSES_LIMIT (20) ids.
const STATUS_BATCH = 20;
const PER_SURFACE = 20;
const MAX_IMMEDIATE = 40;

const MAX_RESTORE_ATTEMPTS = 2;

let surfaceGeneration = 0;
let restoreArmed = false;
let legacyRefreshArmed = false;
let restoreQueue = [];
let restoreTimer = null;
let restoreAttempts = new Map();
const visibleSources = new Map();

// One status can be on screen in more than one column. Leaving a single
// column must not forget the copy that is still visible.
export function noteStatusVisibility(id, visible, source = 'default') {
  if (id === null || id === undefined || id === '') {
    return;
  }

  const key = String(id);
  const label = source === null || source === undefined || source === '' ? 'default' : String(source);
  const sources = visibleSources.get(key) || new Set();

  if (visible) {
    sources.add(label);
    visibleSources.set(key, sources);
    return;
  }

  sources.delete(label);

  if (sources.size === 0) {
    visibleSources.delete(key);
  }
}

const eachVisibleId = callback => {
  visibleSources.forEach((_sources, id) => callback(id));
};

export function releaseVisibilitySource(source) {
  if (source === null || source === undefined || source === '') {
    return;
  }

  const prefix = String(source);
  const stale = [];

  visibleSources.forEach((sources, id) => {
    sources.forEach(label => {
      if (label === prefix || label.startsWith(`${prefix}:`)) {
        stale.push([id, label]);
      }
    });
  });

  stale.forEach(([id, label]) => noteStatusVisibility(id, false, label));
}

export function resetEmojiMuteSurfaces() {
  surfaceGeneration += 1;
  restoreArmed = false;
  legacyRefreshArmed = false;
  restoreQueue = [];
  restoreAttempts = new Map();
  visibleSources.clear();
  if (restoreTimer !== null) {
    clearTimeout(restoreTimer);
    restoreTimer = null;
  }
}

// Preserve the existing test reset API while sharing the same production cleanup.
export const resetEmojiMuteSurfaceForTests = resetEmojiMuteSurfaces;

const surfaceRefreshCurrent = generation => generation === surfaceGeneration;

const needsRestore = (state, id) => {
  const applied = appliedEmojiMuteRevision();
  const status = state.getIn(['statuses', id]);

  if (!status || typeof status.get !== 'function' || applied === null || applied === undefined) {
    return false;
  }

  const revision = status.get('emoji_mutes_revision');

  return revision !== null && revision !== undefined && revisionStale(applied, revision);
};

// A status imported while the mute document was unsettled can lack both
// reactions and a revision. Refetch it only after the viewer rules are ready.
const needsWithheldRestore = (state, id) => emojiReactionEventsAccepted() &&
  state.getIn(['statuses', id, 'emoji_reactions_withheld']) === true;

// A custom group from a cache written before parts has a domain or URL and
// no identity list. Hiding it by the representative domain would drop a
// different emoji that shares the name.
const hasLegacyCustomGroup = status => {
  const reactions = status && typeof status.get === 'function' ? status.get('emoji_reactions') : null;

  if (!reactions || typeof reactions.some !== 'function') {
    return false;
  }

  return reactions.some(group => {
    if (!group || typeof group.get !== 'function') {
      return false;
    }

    const parts = group.get('parts');

    if (parts && typeof parts.size === 'number' && parts.size > 0) {
      return false;
    }

    return !!(group.get('domain') || group.get('url') || group.get('static_url'));
  });
};

const statusNeedsFetch = (state, id, withheldOnly = false) => {
  if (needsWithheldRestore(state, id)) {
    return true;
  }

  if (withheldOnly) {
    return false;
  }

  if (needsRestore(state, id)) {
    return true;
  }

  if (!legacyRefreshArmed) {
    return false;
  }

  return hasLegacyCustomGroup(state.getIn(['statuses', id]));
};

const consider = (ids, state, id, withheldOnly = false) => {
  if (ids.length >= MAX_IMMEDIATE || id === null || id === undefined || id === '') {
    return;
  }

  const key = String(id);

  if (ids.indexOf(key) !== -1 || !statusNeedsFetch(state, key, withheldOnly)) {
    return;
  }

  ids.push(key);
};

const headIds = list => {
  const head = [];

  if (list && typeof list.forEach === 'function') {
    list.forEach(id => {
      if (head.length < PER_SURFACE && id !== null && id !== undefined && id !== '') {
        head.push(String(id));
      }
    });
  }

  return head;
};

// The open thread and the head of every column, at most 40 statuses.
// A normal startup only refetches statuses explicitly marked as withheld;
// unmute/legacy refreshes keep their existing revision-based behavior.
export const immediateStatusIdsForMuteRestore = (state, { withheldOnly = false } = {}) => {
  const ids = [];

  eachVisibleId(id => consider(ids, state, id, withheldOnly));

  const contexts = state.get('contexts');

  if (contexts && typeof contexts.get === 'function') {
    let contextTaken = 0;
    const considerContext = id => {
      if (contextTaken >= PER_SURFACE) {
        return;
      }

      const before = ids.length;
      consider(ids, state, id, withheldOnly);

      if (ids.length > before) {
        contextTaken += 1;
      }
    };

    ['inReplyTos', 'replies', 'references'].forEach(key => {
      const map = contexts.get(key);

      if (!map || typeof map.forEach !== 'function') {
        return;
      }

      map.forEach((value, id) => {
        considerContext(id);

        if (value && typeof value.forEach === 'function') {
          headIds(value).forEach(considerContext);
        } else {
          considerContext(value);
        }
      });
    });
  }

  const heads = [];
  const timelines = state.get('timelines');

  if (timelines && typeof timelines.forEach === 'function') {
    timelines.forEach(timeline => {
      const items = timeline && typeof timeline.get === 'function' ? timeline.get('items') : null;
      heads.push(headIds(items));
    });
  }

  for (let index = 0; index < PER_SURFACE && ids.length < MAX_IMMEDIATE; index += 1) {
    heads.forEach(head => {
      if (index < head.length) {
        consider(ids, state, head[index], withheldOnly);
      }
    });
  }

  return ids;
};

const fetchStatusIds = (ids, generation, dispatch, getState) => {
  let chain = Promise.resolve([]);

  for (let index = 0; index < ids.length; index += STATUS_BATCH) {
    const batch = ids.slice(index, index + STATUS_BATCH);

    chain = chain.then(failed => {
      if (!surfaceRefreshCurrent(generation) || batch.length === 0) {
        return failed;
      }

      const query = batch.map(id => `ids[]=${encodeURIComponent(id)}`).join('&');

      return api(getState).get(`/api/v1/statuses?${query}`).then(response => {
        if (!surfaceRefreshCurrent(generation) || !Array.isArray(response.data)) {
          return failed.concat(batch);
        }

        dispatch(importFetchedStatuses(response.data));
        batch.forEach(id => restoreAttempts.delete(id));
        return failed;
      }).catch(() => failed.concat(batch));
    });
  }

  return chain;
};

const rememberMarkers = (dispatch, getState) => {
  const state = getState();
  const homeItems = state.getIn(['timelines', 'home', 'items']);
  const markers = state.get('markers');

  if (!homeItems || typeof homeItems.find !== 'function' || !markers || typeof markers.get !== 'function') {
    return;
  }

  dispatch(submitMarkers());
};

const rememberRelationships = (dispatch, getState, notifications) => {
  const relationships = getState().get('relationships');

  if (!relationships || typeof relationships.get !== 'function') {
    return;
  }

  const accountIds = notifications.map(item => item && item.account && item.account.id).filter(Boolean);

  if (accountIds.length > 0) {
    dispatch(fetchRelationships(accountIds));
  }
};

// Only the newest refresh may replace what is on screen. Status restores do
// not run ahead of the notification request. A failed notification request
// is not an empty list, and an older page cannot overwrite a newer one.
export function refreshEmojiMuteSurfaces(options = {}) {
  return (dispatch, getState) => {
    if (restoreTimer !== null) {
      clearTimeout(restoreTimer);
      restoreTimer = null;
    }

    const generation = surfaceGeneration + 1;
    const notificationEpoch = emojiMuteNotificationFetchEpoch();
    surfaceGeneration = generation;
    restoreQueue = [];
    restoreAttempts = new Map();

    if (options.restoreStatuses) {
      restoreArmed = true;
    }

    if (options.refetchLegacy) {
      legacyRefreshArmed = true;
      restoreArmed = true;
    }

    const restoring = options.restoreStatuses || options.refetchLegacy || options.restoreWithheld;
    const withheldOnly = options.restoreWithheld && !options.restoreStatuses && !options.refetchLegacy;
    const immediateIds = restoring
      ? immediateStatusIdsForMuteRestore(getState(), { withheldOnly })
      : [];
    const immediateSet = new Set(immediateIds);

    if (restoring) {
      eachVisibleId(id => {
        if (!immediateSet.has(id) && statusNeedsFetch(getState(), id, withheldOnly)) {
          restoreQueue.push(id);
        }
      });
    }

    const statusTask = immediateIds.length > 0
      ? fetchStatusIds(immediateIds, generation, dispatch, getState).then(failed => enqueueRetry(failed, generation, dispatch, getState))
      : Promise.resolve([]);

    if (restoreQueue.length > 0) {
      scheduleRestore(dispatch, getState);
    }

    // A hidden notification must not be counted in the badge if it is not
    // included in the list. Snapshot the filter for both API requests.
    const params = { exclude_types: notificationExcludeTypes(getState()) };
    const readIdAtRequest = getState().getIn(['notifications', 'lastReadId'], '0');
    const unreadAtRequest = getState().getIn(['notifications', 'unread'], 0);
    // A local read can precede the server's acknowledgement even before
    // this refresh starts. Such an unread_count response can still be stale.
    const acknowledgedReadId = getState().getIn(['markers', 'notifications'], null);
    const readNotAcknowledged = acknowledgedReadId !== null && compareId(readIdAtRequest, String(acknowledgedReadId)) > 0;
    const notificationTask = options.skipNotifications ? Promise.resolve(null) : api(getState).get('/api/v1/notifications', { params }).then(response => {
      if (!surfaceRefreshCurrent(generation) || notificationEpoch !== emojiMuteNotificationFetchEpoch() || !Array.isArray(response.data)) {
        return null;
      }

      const notifications = response.data;

      dispatch(importFetchedAccounts(notifications.map(item => item && item.account).filter(Boolean)));
      dispatch(importFetchedAccounts(notifications.map(item => item && item.report && item.report.target_account).filter(Boolean)));
      dispatch(importFetchedStatuses(notifications.map(item => item && item.status).filter(Boolean)));

      const deliver = unread => {
        if (!surfaceRefreshCurrent(generation) || notificationEpoch !== emojiMuteNotificationFetchEpoch()) {
          return null;
        }

        // The server count might have been computed before the user read
        // notifications while these requests were in flight.
        const latestState = getState();
        const readAdvanced = compareId(latestState.getIn(['notifications', 'lastReadId'], '0'), readIdAtRequest) > 0;
        const unreadReduced = latestState.getIn(['notifications', 'unread'], 0) < unreadAtRequest;
        dispatch({
          type: NOTIFICATIONS_FEED_MERGE,
          notifications,
          rules: currentEmojiMutes(),
          unread: readNotAcknowledged || readAdvanced || unreadReduced ? undefined : unread,
        });
        rememberRelationships(dispatch, getState, notifications);
        rememberMarkers(dispatch, getState);
        return notifications;
      };

      return api(getState).get('/api/v1/notifications/unread_count', { params }).then(unreadResponse => {
        const count = unreadResponse && unreadResponse.data ? unreadResponse.data.count : undefined;

        return deliver(typeof count === 'number' ? count : undefined);
      }).catch(() => deliver(undefined));
    }, () => null);

    return Promise.all([statusTask, notificationTask]).then(() => null);
  };
}

const enqueueRetry = (failed, generation, dispatch, getState) => {
  if (!surfaceRefreshCurrent(generation)) {
    return;
  }

  (failed || []).forEach(id => {
    const attempts = restoreAttempts.get(id) || 0;

    if (attempts + 1 < MAX_RESTORE_ATTEMPTS) {
      restoreAttempts.set(id, attempts + 1);
      restoreQueue.push(id);
    }
  });

  if (restoreQueue.length > 0) {
    scheduleRestore(dispatch, getState);
  }
};

const scheduleRestore = (dispatch, getState) => {
  if (restoreTimer !== null) {
    return;
  }

  const generation = surfaceGeneration;

  restoreTimer = setTimeout(() => {
    restoreTimer = null;

    if (!surfaceRefreshCurrent(generation)) {
      return;
    }

    const pending = [];
    const seen = new Set();

    restoreQueue.forEach(id => {
      if (!seen.has(id)) {
        seen.add(id);
        pending.push(id);
      }
    });

    const batch = pending.slice(0, STATUS_BATCH);
    restoreQueue = pending.slice(STATUS_BATCH);

    if (batch.length === 0) {
      return;
    }

    fetchStatusIds(batch, generation, dispatch, getState).then(failed => {
      if (!surfaceRefreshCurrent(generation)) {
        return;
      }

      enqueueRetry(failed, generation, dispatch, getState);
    }).catch(() => {});

    if (restoreQueue.length > 0) {
      scheduleRestore(dispatch, getState);
    }
  }, 0);
};

// A status that is already on screen, or opened after the rules change,
// refetches only itself. The refresh pass does not walk the whole cache.
export function restoreVisibleEmojiMuteStatus(id) {
  return (dispatch, getState) => {
    const state = getState();
    if ((!restoreArmed && !legacyRefreshArmed && !needsWithheldRestore(state, id)) || !statusNeedsFetch(state, id)) {
      return;
    }

    restoreQueue.push(String(id));
    scheduleRestore(dispatch, getState);
  };
}

let documentSyncGeneration = 0;
let initialDocumentSync = null;
// Only the newest sync owns the notice. An older request can still be on
// the network, and that must not keep a newer failure hidden.
let emojiMuteCurrentSyncPending = false;

export function emojiMuteSyncInFlight() {
  return emojiMuteCurrentSyncPending;
}

export function emojiMuteSyncGeneration() {
  return documentSyncGeneration;
}
let initialDocumentRequestVersion = null;

function plainInitialFollowUp(options) {
  return !options.bootstrap && !options.reconnect && !options.changed && options.verify !== true;
}

function initialDocumentStillCurrent() {
  return initialDocumentSync && initialDocumentRequestVersion === emojiMuteRequestVersion();
}

// A viewer boundary invalidates both in-flight document continuations and
// queued status/notification refreshes. Resetting only the document module
// would leave stale surface work live in the previous viewer's Redux tree.
export function invalidateEmojiMuteAsyncWork() {
  documentSyncGeneration += 1;
  // The invalidated sync no longer owns the notice. Its later release must
  // not clear a fetch the next shell has started.
  emojiMuteCurrentSyncPending = false;
  initialDocumentSync = null;
  initialDocumentRequestVersion = null;
  resetEmojiMuteSurfaces();
}

// A stream event can make the local document stale before the new GET resolves.
// An older asynchronous continuation must never republish earlier rules.
export function syncEmojiMutes(options = {}) {
  return (dispatch, getState) => {
    // Explicit recovery mode is scoped to this tab and account. Do not fetch
    // rules, or let a later streaming revision put the UI back into stale.
    if (emojiMuteBypassEnabled()) {
      dispatch({
        type: EMOJI_MUTES_APPLY,
        mutes: [],
        revision: '0',
        recovered: true,
      });
      return Promise.resolve([]);
    }

    if (options.reconnect && currentEmojiMuteBoot().availability === 'disabled') {
      const confirmation = beginEmojiMutePreferenceConfirmation();
      noteEmojiMutePreferenceConfirming();
      dispatch({ type: EMOJI_MUTES_CONFIRM });
      const generation = beginEmojiMutePreferenceRead();

      return dispatch(applyRemoteEmojiMutePreference({ generation })).catch(error => {
        if (!emojiMutePreferenceReadCurrent(generation) || !emojiMutePreferenceConfirmationCurrent(confirmation)) {
          return null;
        }

        endEmojiMutePreferenceConfirmation(confirmation);
        dispatch({
          type: EMOJI_MUTES_FAIL,
          failure: classifyEmojiMuteFetchError(error),
        });
        return null;
      });
    }

    if (currentEmojiMuteBoot().availability === 'disabled') {
      dispatch({ type: EMOJI_MUTES_DISABLE });
      return Promise.resolve([]);
    }

    if (emojiMuteTemporarilyIgnored()) {
      dispatch({ type: EMOJI_MUTES_IGNORE });
      return Promise.resolve([]);
    }

    // The user stream connects while the first fetch is still running.
    // Joining it keeps that fetch from being superseded and refreshing
    // notifications before the columns exist. A preference change that
    // already invalidated the request must start its own GET.
    if (initialDocumentStillCurrent() && plainInitialFollowUp(options)) {
      return initialDocumentSync;
    }

    const generation = ++documentSyncGeneration;
    emojiMuteCurrentSyncPending = true;
    let syncReleased = false;
    const releaseSync = () => {
      if (syncReleased) {
        return;
      }

      syncReleased = true;

      if (generation === documentSyncGeneration) {
        emojiMuteCurrentSyncPending = false;
      }
    };
    const preferenceGeneration = emojiMutePreferenceGeneration();
    const previousRevision = appliedEmojiMuteRevision();
    const previousSignature = hideReactionSignature(currentEmojiMutes());
    const pending = options.changed ? noteEmojiMutesChanged(options.changed) : loadEmojiMutes({
      force: options.verify === true,
      strict: options.verify === true,
    });

    if (options.changed) {
      dispatch(importEmojiMutesRevision(observedEmojiMuteRevision()));
    } else {
      dispatch({ type: EMOJI_MUTES_LOAD, verify: options.verify === true });
    }

    const syncPromise = pending.then(mutes => {
      if (generation !== documentSyncGeneration) {
        // An older success must not be read as "this sync failed".
        return { superseded: true };
      }

      if (currentEmojiMuteBoot().availability === 'disabled') {
        dispatch({ type: EMOJI_MUTES_DISABLE });
        if (options.bootstrap) {
          return refreshEmojiMuteSurfaces({
            restoreWithheld: true,
            skipNotifications: true,
          })(dispatch, getState).then(() => mutes);
        }

        return dispatch(revealEmojiMuteEffects(previousSignature)).then(() => mutes);
      }

      // Ignore or a completed OFF happened while this GET was in flight.
      // Adopting it would replace that recovery with the old request.
      if (emojiMuteTemporarilyIgnored()) {
        return mutes;
      }

      // A request may resolve successfully while returning a document older
      // than a streaming revision. An unresolved gap is a failure, not an
      // endless loading spinner. The WebUI stays mounted and emoji stay hidden.
      if (!emojiMuteDocumentReady()) {
        if (preferenceGeneration !== emojiMutePreferenceGeneration()) {
          // A newer preference read owns the outcome. Do not adopt this
          // snapshot and do not replace the confirmed failure with ready.
          return null;
        }

        // A fulfilled GET can still be a failure, for example an older
        // revision. Clear this sync before the failure dispatch, or the
        // observer still treats it as in flight and the card stays hidden.
        releaseSync();
        dispatch({
          type: EMOJI_MUTES_FAIL,
          failure: emojiMuteAuthorizationFailure() || 'unavailable',
        });
        return null;
      }

      const nextRevision = appliedEmojiMuteRevision();
      const nextSignature = hideReactionSignature(mutes);
      const sameDocument = previousRevision !== null && previousRevision === nextRevision;
      const hideShrunk = hideSignatureShrunk(previousSignature, nextSignature);
      const hideGrew = hideSignatureGrew(previousSignature, nextSignature);

      dispatch({
        type: EMOJI_MUTES_APPLY,
        mutes,
        revision: nextRevision,
        sameDocument,
        hideShrunk,
        availability: currentEmojiMuteBoot().availability === 'enabled' ? 'enabled' : undefined,
        // A duplicate stream event never reaches this apply while an
        // authorization failure is latched. This flag is the successful GET.
        recovered: true,
      });

      // The first mount skips the notification round trip. A stream connect
      // that finds the same document does too: the column loads that list
      // itself. A changed document or a reconnect still refreshes it.
      // Statuses imported with reactions withheld are restored either way.
      if (options.bootstrap || (sameDocument && !options.reconnect && !hideShrunk && !hideGrew)) {
        return refreshEmojiMuteSurfaces({
          restoreWithheld: true,
          skipNotifications: true,
        })(dispatch, getState).then(() => mutes);
      }

      return refreshEmojiMuteSurfaces({
        restoreStatuses: hideShrunk && !sameDocument,
        refetchLegacy: hideGrew && !sameDocument,
        restoreWithheld: true,
      })(dispatch, getState);
    }).catch(error => {
      if (generation !== documentSyncGeneration) {
        // The component that started this request has its own counter. Mark
        // the rejection so a newer sync can own the notice.
        error.superseded = true;
        throw error;
      }

      if (emojiMuteTemporarilyIgnored() || currentEmojiMuteBoot().availability === 'disabled') {
        return null;
      }

      const failure = classifyEmojiMuteFetchError(error);
      // A confirmed document stays applied through a dropped connection.
      // An expired or forbidden token hides emoji until a later GET adopts a
      // current document. The WebUI itself stays mounted.
      const sessionRejected = failure === 'unauthorized' || failure === 'forbidden';

      if (sessionRejected) {
        blockEmojiMuteAuthorization(failure);
      }

      const blocked = emojiMuteAuthorizationFailure();

      if (blocked || sessionRejected || options.verify === true || !emojiMuteDocumentReady()) {
        // The failure dispatch is this request's outcome, not another in-flight sync.
        releaseSync();
        dispatch({ type: EMOJI_MUTES_FAIL, failure: blocked || failure });
      }

      throw error;
    });
    const settled = syncPromise.finally(() => {
      // Release before notifying. A quiet completion, such as a list that
      // lost to a newer preference read, otherwise leaves retry disabled.
      // An older generation must not announce settlement over a newer sync.
      const stillNewest = generation === documentSyncGeneration;
      releaseSync();

      if (stillNewest) {
        dispatch({ type: EMOJI_MUTES_SYNC_SETTLED });
      }
    });

    if (options.bootstrap === true && !options.changed && options.verify !== true && !options.reconnect) {
      let tracked;
      tracked = settled.finally(() => {
        if (initialDocumentSync === tracked) {
          initialDocumentSync = null;
          initialDocumentRequestVersion = null;
        }
      });
      initialDocumentRequestVersion = emojiMuteRequestVersion();
      initialDocumentSync = tracked;
      return tracked;
    }

    return settled;
  };
}
