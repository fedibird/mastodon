import api from 'mastodon/api';
import { importFetchedAccounts, importFetchedStatuses } from './importer';
import { NOTIFICATIONS_RELOAD_SUCCESS } from './notifications';
import {
  appliedEmojiMuteRevision,
  loadEmojiMutes,
  noteEmojiMutesChanged,
} from '../features/emoji/emoji_mute_store';

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

const STATUS_BATCH = 40;

let surfaceGeneration = 0;

const addId = (ids, id) => {
  if (id !== null && id !== undefined && id !== '') {
    ids.push(String(id));
  }
};

const addList = (ids, list) => {
  if (list && typeof list.forEach === 'function') {
    list.forEach(id => addId(ids, id));
  }
};

// Detail threads first, then every column, then loaded statuses that are not
// in a timeline. Requests are batched. Nothing is dropped after 40 ids.
export const statusIdsForMuteRefresh = state => {
  const ids = [];
  const contexts = state.get('contexts');

  if (contexts && typeof contexts.get === 'function') {
    ['inReplyTos', 'replies', 'references'].forEach(key => {
      const map = contexts.get(key);

      if (map && typeof map.forEach === 'function') {
        map.forEach((value, id) => {
          addId(ids, id);

          if (value && typeof value.forEach === 'function') {
            addList(ids, value);
          } else {
            addId(ids, value);
          }
        });
      }
    });
  }

  const timelines = state.get('timelines');

  if (timelines && typeof timelines.forEach === 'function') {
    timelines.forEach(timeline => {
      const items = timeline && typeof timeline.get === 'function' ? timeline.get('items') : null;
      addList(ids, items);
    });
  }

  const statuses = state.get('statuses');

  if (statuses && typeof statuses.forEach === 'function') {
    statuses.forEach((status, id) => {
      if (status && typeof status.get === 'function' && status.get('emoji_reactions')) {
        addId(ids, id);
      }
    });
  }

  return Array.from(new Set(ids));
};

const surfaceRefreshCurrent = generation => generation === surfaceGeneration;

const fetchStatusBatch = (ids, getState) => Promise.all(ids.map(id => (
  api(getState).get(`/api/v1/statuses/${id}`).then(response => response.data).catch(() => null)
)));

// Only the newest refresh may replace what is on screen. An older status
// batch stops when a newer refresh starts. An older notification page or
// unread count is dropped even if it arrives after the newer result. A
// failed notification request is not an empty list.
export function refreshEmojiMuteSurfaces() {
  return (dispatch, getState) => {
    const generation = surfaceGeneration + 1;
    surfaceGeneration = generation;
    const ids = statusIdsForMuteRefresh(getState());

    const fetchStatuses = async () => {
      for (let index = 0; index < ids.length; index += STATUS_BATCH) {
        if (!surfaceRefreshCurrent(generation)) {
          return;
        }

        const bodies = await fetchStatusBatch(ids.slice(index, index + STATUS_BATCH), getState);

        if (!surfaceRefreshCurrent(generation)) {
          return;
        }

        dispatch(importFetchedStatuses(bodies.filter(Boolean)));
      }
    };

    return fetchStatuses().then(() => {
      if (!surfaceRefreshCurrent(generation)) {
        return null;
      }

      return api(getState).get('/api/v1/notifications', { params: { limit: 40 } }).then(response => {
        if (!surfaceRefreshCurrent(generation) || !Array.isArray(response.data)) {
          return null;
        }

        const notifications = response.data;

        dispatch(importFetchedAccounts(notifications.map(item => item && item.account).filter(Boolean)));
        dispatch(importFetchedAccounts(notifications.map(item => item && item.report && item.report.target_account).filter(Boolean)));
        dispatch(importFetchedStatuses(notifications.map(item => item && item.status).filter(Boolean)));

        return api(getState).get('/api/v1/notifications/unread_count').then(unreadResponse => {
          if (!surfaceRefreshCurrent(generation)) {
            return null;
          }

          dispatch({
            type: NOTIFICATIONS_RELOAD_SUCCESS,
            notifications,
            unread: unreadResponse.data.count,
          });
          return notifications;
        }).catch(() => {
          if (!surfaceRefreshCurrent(generation)) {
            return null;
          }

          dispatch({
            type: NOTIFICATIONS_RELOAD_SUCCESS,
            notifications,
          });
          return notifications;
        });
      }, () => null);
    });
  };
}

export function syncEmojiMutes(options = {}) {
  return (dispatch, getState) => {
    const pending = options.changed ? noteEmojiMutesChanged(options.changed) : loadEmojiMutes();

    return pending.then(mutes => {
      dispatch({
        type: EMOJI_MUTES_APPLY,
        mutes,
        revision: appliedEmojiMuteRevision(),
      });
      return refreshEmojiMuteSurfaces()(dispatch, getState);
    });
  };
}
