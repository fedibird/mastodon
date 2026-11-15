import api from '../api';
import { COMPOSER_DRAFT_MEDIA, targetComposerAction } from '../actions/composer';
import { draftMediaResponseUsable } from './snapshot';

export function resolveDraftMedia (composerId, snapshot, restoreToken) {
  return (dispatch, getState) => {
    const media = snapshot && snapshot.input && Array.isArray(snapshot.input.media) ? snapshot.input.media : [];

    if (!restoreToken || media.length === 0) {
      return Promise.resolve();
    }

    const senderId = senderIdFromSnapshot(snapshot);

    return Promise.all(media.map(item => fetchDraftMedia(dispatch, getState, composerId, restoreToken, item, senderId)));
  };
}

function senderIdFromSnapshot (snapshot) {
  const sender = snapshot && snapshot.input && snapshot.input.sender;
  const id = sender && sender.id !== undefined && sender.id !== null ? String(sender.id) : '';

  return id;
}

function fetchDraftMedia (dispatch, getState, composerId, restoreToken, item, senderId) {
  const mediaId = item && item.id !== undefined && item.id !== null ? String(item.id) : '';

  if (!mediaId) {
    return Promise.resolve();
  }

  const config = senderId ? { params: { posting_identity_id: senderId } } : {};

  return api(getState).get(`/api/v1/media/${mediaId}`, config).then(response => {
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
