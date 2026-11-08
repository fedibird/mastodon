import api from 'mastodon/api';
import { importFetchedAccounts, importFetchedStatuses } from './importer';
import { NOTIFICATIONS_FEED_MERGE, notificationExcludeTypes } from './notifications';
import { submitMarkers } from './markers';
import { fetchRelationships } from './accounts';
import {
  appliedEmojiMuteRevision,
  currentEmojiMutes,
  loadEmojiMutes,
  noteEmojiMutesChanged,
} from '../features/emoji/emoji_mute_store';
import { hideReactionSignature, hideSignatureShrunk, revisionStale } from '../features/emoji/emoji_mute_projection';

export const EMOJI_MUTES_IMPORT = 'EMOJI_MUTES_IMPORT';
export const EMOJI_MUTES_REVISION = 'EMOJI_MUTES_REVISION';
export const EMOJI_MUTES_APPLY = 'EMOJI_MUTES_APPLY';

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

let surfaceGeneration = 0;
let restoreArmed = false;
let restoreQueue = [];
let restoreTimer = null;

export function resetEmojiMuteSurfaceForTests() {
  surfaceGeneration += 1;
  restoreArmed = false;
  restoreQueue = [];
  if (restoreTimer !== null) {
    clearTimeout(restoreTimer);
    restoreTimer = null;
  }
}

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

const consider = (ids, state, id) => {
  if (ids.length >= MAX_IMMEDIATE || id === null || id === undefined || id === '') {
    return;
  }

  const key = String(id);

  if (ids.indexOf(key) !== -1 || !needsRestore(state, key)) {
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

// The open thread and the head of every column, at most 40 statuses whose
// stored revision is behind the applied document. Loaded statuses that are
// not on screen are restored when they are shown, not in this pass.
export const immediateStatusIdsForMuteRestore = state => {
  const ids = [];
  const contexts = state.get('contexts');

  if (contexts && typeof contexts.get === 'function') {
    let contextTaken = 0;
    const considerContext = id => {
      if (contextTaken >= PER_SURFACE) {
        return;
      }

      const before = ids.length;
      consider(ids, state, id);

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
        consider(ids, state, head[index]);
      }
    });
  }

  return ids;
};

const fetchStatusIds = (ids, generation, dispatch, getState) => {
  let chain = Promise.resolve();

  for (let index = 0; index < ids.length; index += STATUS_BATCH) {
    const batch = ids.slice(index, index + STATUS_BATCH);

    chain = chain.then(() => {
      if (!surfaceRefreshCurrent(generation) || batch.length === 0) {
        return null;
      }

      const query = batch.map(id => `ids[]=${encodeURIComponent(id)}`).join('&');

      return api(getState).get(`/api/v1/statuses?${query}`).then(response => {
        if (!surfaceRefreshCurrent(generation) || !Array.isArray(response.data)) {
          return null;
        }

        dispatch(importFetchedStatuses(response.data));
        return response.data;
      }).catch(() => null);
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
    const generation = surfaceGeneration + 1;
    surfaceGeneration = generation;
    restoreQueue = [];

    if (options.restoreStatuses) {
      restoreArmed = true;
    }

    const statusTask = options.restoreStatuses
      ? fetchStatusIds(immediateStatusIdsForMuteRestore(getState()), generation, dispatch, getState)
      : Promise.resolve();

    const notificationTask = api(getState).get('/api/v1/notifications', {
      params: { exclude_types: notificationExcludeTypes(getState()) },
    }).then(response => {
      if (!surfaceRefreshCurrent(generation) || !Array.isArray(response.data)) {
        return null;
      }

      const notifications = response.data;

      dispatch(importFetchedAccounts(notifications.map(item => item && item.account).filter(Boolean)));
      dispatch(importFetchedAccounts(notifications.map(item => item && item.report && item.report.target_account).filter(Boolean)));
      dispatch(importFetchedStatuses(notifications.map(item => item && item.status).filter(Boolean)));

      const deliver = unread => {
        if (!surfaceRefreshCurrent(generation)) {
          return null;
        }

        dispatch({
          type: NOTIFICATIONS_FEED_MERGE,
          notifications,
          rules: currentEmojiMutes(),
          unread,
        });
        rememberRelationships(dispatch, getState, notifications);
        rememberMarkers(dispatch, getState);
        return notifications;
      };

      return api(getState).get('/api/v1/notifications/unread_count').then(unreadResponse => {
        const count = unreadResponse && unreadResponse.data ? unreadResponse.data.count : undefined;

        return deliver(typeof count === 'number' ? count : undefined);
      }).catch(() => deliver(undefined));
    }, () => null);

    return Promise.all([statusTask, notificationTask]).then(() => null);
  };
}

const scheduleRestore = (dispatch, getState) => {
  if (restoreTimer !== null) {
    return;
  }

  const generation = surfaceGeneration;

  restoreTimer = setTimeout(() => {
    restoreTimer = null;
    const ids = Array.from(new Set(restoreQueue)).slice(0, STATUS_BATCH);
    restoreQueue = [];

    if (!surfaceRefreshCurrent(generation) || ids.length === 0) {
      return;
    }

    fetchStatusIds(ids, generation, dispatch, getState);
  }, 0);
};

// A status that is already on screen, or opened after the rules change,
// refetches only itself. The refresh pass does not walk the whole cache.
export function restoreVisibleEmojiMuteStatus(id) {
  return (dispatch, getState) => {
    if (!restoreArmed || !needsRestore(getState(), id)) {
      return;
    }

    restoreQueue.push(String(id));
    scheduleRestore(dispatch, getState);
  };
}

export function syncEmojiMutes(options = {}) {
  return (dispatch, getState) => {
    const previousRevision = appliedEmojiMuteRevision();
    const previousSignature = hideReactionSignature(currentEmojiMutes());
    const pending = options.changed ? noteEmojiMutesChanged(options.changed) : loadEmojiMutes();

    return pending.then(mutes => {
      const nextRevision = appliedEmojiMuteRevision();
      const nextSignature = hideReactionSignature(mutes);
      const sameDocument = previousRevision !== null && previousRevision === nextRevision;
      const hideShrunk = hideSignatureShrunk(previousSignature, nextSignature);

      dispatch({
        type: EMOJI_MUTES_APPLY,
        mutes,
        revision: nextRevision,
        sameDocument,
        hideShrunk,
      });
      return refreshEmojiMuteSurfaces({ restoreStatuses: hideShrunk && !sameDocument })(dispatch, getState);
    });
  };
}
