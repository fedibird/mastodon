import api from '../api';
import { COMPOSER_DRAFT_MEDIA, targetComposerAction } from '../actions/composer';
import { draftMediaResponseUsable } from './snapshot';

export function resolveDraftMedia (composerId, snapshot, restoreToken) {
  return (dispatch, getState) => {
    const media = snapshot && snapshot.input && Array.isArray(snapshot.input.media) ? snapshot.input.media : [];

    if (!restoreToken || media.length === 0) {
      return Promise.resolve();
    }

    return Promise.all(media.map(item => fetchDraftMedia(dispatch, getState, composerId, restoreToken, item)));
  };
}

function fetchDraftMedia (dispatch, getState, composerId, restoreToken, item) {
  const mediaId = item && item.id !== undefined && item.id !== null ? String(item.id) : '';

  if (!mediaId) {
    return Promise.resolve();
  }

  return api(getState).get(`/api/v1/media/${mediaId}`).then(response => {
    if (!response || response.status !== 200 || !draftMediaResponseUsable(response.data, mediaId)) {
      return;
    }

    dispatch(targetComposerAction({
      type: COMPOSER_DRAFT_MEDIA,
      restoreToken,
      mediaId,
      media: response.data,
    }, composerId));
  }).catch(() => {});
}
