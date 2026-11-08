import api from 'mastodon/api';
import { importFetchedStatuses } from './importer';
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

const visibleStatusIds = state => {
  const ids = [];
  const timelines = state.get('timelines');

  if (timelines && typeof timelines.forEach === 'function') {
    timelines.forEach(timeline => {
      const items = timeline && typeof timeline.get === 'function' ? timeline.get('items') : null;

      if (items && typeof items.forEach === 'function') {
        items.forEach(id => {
          if (id) {
            ids.push(String(id));
          }
        });
      }
    });
  }

  return Array.from(new Set(ids)).slice(0, 40);
};

export function refreshEmojiMuteSurfaces() {
  return (dispatch, getState) => {
    const ids = visibleStatusIds(getState());
    const statuses = Promise.all(ids.map(id => api(getState).get(`/api/v1/statuses/${id}`).then(response => response.data).catch(() => null)));
    const notifications = api(getState).get('/api/v1/notifications', { params: { limit: 40 } }).then(response => response.data).catch(() => []);
    const unread = api(getState).get('/api/v1/notifications/unread_count').then(response => response.data.count).catch(() => null);

    return Promise.all([statuses, notifications, unread]).then(([statusBodies, notificationBodies, unreadCount]) => {
      dispatch(importFetchedStatuses(statusBodies.filter(Boolean)));
      dispatch({
        type: NOTIFICATIONS_RELOAD_SUCCESS,
        notifications: notificationBodies,
        unread: unreadCount,
      });
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
