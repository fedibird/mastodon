import api from '../api';
import { selectComposer } from '../selectors/composer';
import { showAlert } from './alerts';
import { targetComposerAction } from './composer';

export const COMPOSE_REDAFT_MEDIA_LOCAL = 'COMPOSE_REDAFT_MEDIA_LOCAL';
export const COMPOSE_REDAFT_MEDIA_STATUS = 'COMPOSE_REDAFT_MEDIA_STATUS';

export const REDRAFT_REUSE_WAITING = 'waiting';
export const REDRAFT_REUSE_READY = 'ready';
export const REDRAFT_REUSE_SAVING = 'saving';
export const REDRAFT_REUSE_FAILED = 'failed';
export const REDRAFT_REUSE_COMPLETE = 'complete';

const REDRAFT_POLL_LIMIT_MS = 30_000;
const REDRAFT_POLL_BASE_MS = 500;
const REDRAFT_POLL_MAX_DELAY_MS = 5_000;

const redraftPolls = new Map();
const redraftSaves = new Map();
const redraftResave = new Set();

const pollKey = (composerId, mediaId) => `${composerId}:${mediaId}`;

const sameMediaId = (left, right) => String(left) === String(right);

const findMedia = (composer, mediaId) => {
  if (!composer) {
    return null;
  }

  return composer.get('media_attachments').find(item => sameMediaId(item.get('id'), mediaId)) || null;
};

const responseStatus = error => error && error.response && error.response.status;

export const focusToken = media => {
  if (!media) {
    return '';
  }

  const x = media.getIn(['meta', 'focus', 'x']);
  const y = media.getIn(['meta', 'focus', 'y']);

  if (x === undefined || x === null || y === undefined || y === null || x === '' || y === '') {
    return '';
  }

  const nx = Number(x);
  const ny = Number(y);

  if (Number.isNaN(nx) || Number.isNaN(ny)) {
    return '';
  }

  return `${nx.toFixed(2)},${ny.toFixed(2)}`;
};

const serverFocusToken = serverMedia => {
  const focus = serverMedia && serverMedia.meta && serverMedia.meta.focus;

  if (!focus || focus.x === undefined || focus.x === null || focus.y === undefined || focus.y === null) {
    return '';
  }

  const x = Number(focus.x);
  const y = Number(focus.y);

  if (Number.isNaN(x) || Number.isNaN(y)) {
    return '';
  }

  return `${x.toFixed(2)},${y.toFixed(2)}`;
};

const metadataMatches = (media, serverMedia) => {
  const serverDescription = (serverMedia && serverMedia.description) || '';
  const localDescription = (media && media.get('description')) || '';

  return localDescription === serverDescription && focusToken(media) === serverFocusToken(serverMedia);
};

const clearPoll = (composerId, mediaId) => {
  const key = pollKey(composerId, mediaId);
  const timer = redraftPolls.get(key);

  if (timer) {
    clearTimeout(timer);
  }

  redraftPolls.delete(key);
};

const statusAction = (composerId, fields) => targetComposerAction({
  type: COMPOSE_REDAFT_MEDIA_STATUS,
  ...fields,
}, composerId);

const currentWaitingMedia = (getState, { composerId, mediaId, epoch }) => {
  const composer = selectComposer(getState(), composerId);

  if (!composer || composer.get('redraftEpoch') !== epoch) {
    return null;
  }

  const media = findMedia(composer, mediaId);

  if (!media || media.get('redraftReuse') !== REDRAFT_REUSE_WAITING) {
    return null;
  }

  return media;
};

const failReuse = (dispatch, context, error) => {
  clearPoll(context.composerId, context.mediaId);
  dispatch(statusAction(context.composerId, {
    mediaId: context.mediaId,
    reuse: REDRAFT_REUSE_FAILED,
    error,
    changingUpload: false,
  }));
};

const markComplete = (dispatch, context, media) => {
  dispatch(statusAction(context.composerId, {
    mediaId: context.mediaId,
    reuse: REDRAFT_REUSE_COMPLETE,
    error: null,
    fetched: true,
    changingUpload: false,
    media,
    keepLocalText: !media,
  }));
};

function saveRedraftMetadata(dispatch, getState, context) {
  const key = pollKey(context.composerId, context.mediaId);
  const composer = selectComposer(getState(), context.composerId);

  if (!composer || composer.get('redraftEpoch') !== context.epoch) {
    return;
  }

  const media = findMedia(composer, context.mediaId);

  if (!media) {
    redraftSaves.delete(key);
    return;
  }

  const revision = media.get('redraftRevision') || 0;

  if (redraftSaves.get(key) === revision) {
    return;
  }

  if (redraftSaves.has(key)) {
    redraftResave.add(key);
    return;
  }

  redraftSaves.set(key, revision);
  clearPoll(context.composerId, context.mediaId);

  dispatch(statusAction(context.composerId, {
    mediaId: media.get('id'),
    reuse: REDRAFT_REUSE_SAVING,
    error: null,
    changingUpload: true,
    expectedRevision: revision,
  }));

  const params = { description: media.get('description') || '' };
  const focus = focusToken(media);

  if (focus) {
    params.focus = focus;
  }

  api(getState).put(`/api/v1/media/${media.get('id')}`, params).then(response => {
    finishSave(dispatch, getState, context, revision, response && response.data);
  }).catch(error => {
    finishSaveError(dispatch, getState, context, revision, error);
  });
}

function finishSave(dispatch, getState, context, revision, serverMedia) {
  const key = pollKey(context.composerId, context.mediaId);

  redraftSaves.delete(key);

  const composer = selectComposer(getState(), context.composerId);
  const media = composer && composer.get('redraftEpoch') === context.epoch
    ? findMedia(composer, context.mediaId)
    : null;

  if (!media) {
    redraftResave.delete(key);
    return;
  }

  if ((media.get('redraftRevision') || 0) !== revision || redraftResave.has(key)) {
    redraftResave.delete(key);
    saveRedraftMetadata(dispatch, getState, context);
    return;
  }

  dispatch(statusAction(context.composerId, {
    mediaId: media.get('id'),
    reuse: REDRAFT_REUSE_COMPLETE,
    error: null,
    fetched: true,
    changingUpload: false,
    expectedRevision: revision,
    media: serverMedia,
    keepLocalText: false,
  }));
}

function finishSaveError(dispatch, getState, context, revision, error) {
  const key = pollKey(context.composerId, context.mediaId);

  redraftSaves.delete(key);

  const composer = selectComposer(getState(), context.composerId);
  const media = composer && composer.get('redraftEpoch') === context.epoch
    ? findMedia(composer, context.mediaId)
    : null;

  if (!media) {
    redraftResave.delete(key);
    return;
  }

  if ((media.get('redraftRevision') || 0) !== revision || redraftResave.has(key)) {
    redraftResave.delete(key);
    saveRedraftMetadata(dispatch, getState, context);
    return;
  }

  const status = responseStatus(error);

  if (status === 404) {
    dispatch(statusAction(context.composerId, {
      mediaId: media.get('id'),
      reuse: REDRAFT_REUSE_WAITING,
      error: null,
      changingUpload: false,
      expectedRevision: revision,
    }));
    pollRedraftMedia(dispatch, getState, { ...context, attempt: 0, startedAt: Date.now() });
    return;
  }

  failReuse(
    dispatch,
    context,
    status === 403 || status === 401 ? 'forbidden' : 'save',
  );
}

function acceptReady(dispatch, getState, context, serverMedia) {
  clearPoll(context.composerId, context.mediaId);

  dispatch(statusAction(context.composerId, {
    mediaId: context.mediaId,
    reuse: REDRAFT_REUSE_READY,
    error: null,
    fetched: true,
    media: serverMedia,
    keepLocalText: true,
  }));

  const composer = selectComposer(getState(), context.composerId);
  const media = composer && findMedia(composer, context.mediaId);

  if (!media) {
    return;
  }

  if (metadataMatches(media, serverMedia)) {
    markComplete(dispatch, context, null);
    return;
  }

  saveRedraftMetadata(dispatch, getState, context);
}

function schedulePoll(dispatch, getState, context) {
  const elapsed = Date.now() - context.startedAt;
  const delay = Math.min(REDRAFT_POLL_BASE_MS * (2 ** context.attempt), REDRAFT_POLL_MAX_DELAY_MS);

  if (elapsed + delay > REDRAFT_POLL_LIMIT_MS) {
    failReuse(dispatch, context, 'prepare');
    return;
  }

  const key = pollKey(context.composerId, context.mediaId);

  clearPoll(context.composerId, context.mediaId);

  const timer = setTimeout(() => {
    redraftPolls.delete(key);
    pollRedraftMedia(dispatch, getState, { ...context, attempt: context.attempt + 1 });
  }, delay);

  redraftPolls.set(key, timer);
}

function pollRedraftMedia(dispatch, getState, context) {
  if (Date.now() - context.startedAt > REDRAFT_POLL_LIMIT_MS) {
    failReuse(dispatch, context, 'prepare');
    return;
  }

  if (!currentWaitingMedia(getState, context)) {
    clearPoll(context.composerId, context.mediaId);
    return;
  }

  api(getState).get(`/api/v1/media/${context.mediaId}`).then(response => {
    if (!currentWaitingMedia(getState, context)) {
      clearPoll(context.composerId, context.mediaId);
      return;
    }

    if (response.status === 200) {
      acceptReady(dispatch, getState, context, response.data);
      return;
    }

    if (response.status === 206) {
      schedulePoll(dispatch, getState, context);
      return;
    }

    failReuse(dispatch, context, 'prepare');
  }).catch(error => {
    if (!currentWaitingMedia(getState, context)) {
      clearPoll(context.composerId, context.mediaId);
      return;
    }

    const status = responseStatus(error);

    if (status === 403 || status === 401) {
      failReuse(dispatch, context, 'forbidden');
      return;
    }

    if (status === 410) {
      failReuse(dispatch, context, 'prepare');
      return;
    }

    schedulePoll(dispatch, getState, context);
  });
}

export function prepareRedraftMedia(composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer) {
      return;
    }

    const epoch = composer.get('redraftEpoch');
    const startedAt = Date.now();

    composer.get('media_attachments').forEach(media => {
      if (media.get('redraftReuse') !== REDRAFT_REUSE_WAITING) {
        return;
      }

      pollRedraftMedia(dispatch, getState, {
        composerId,
        mediaId: media.get('id'),
        epoch,
        attempt: 0,
        startedAt,
      });
    });
  };
}

export function retryRedraftMedia(composerId) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);

    if (!composer) {
      return;
    }

    const epoch = composer.get('redraftEpoch');

    composer.get('media_attachments').forEach(media => {
      if (media.get('redraftReuse') !== REDRAFT_REUSE_FAILED) {
        return;
      }

      if (media.get('redraftFetched') === true && media.get('redraftError') === 'save') {
        saveRedraftMetadata(dispatch, getState, {
          composerId,
          mediaId: media.get('id'),
          epoch,
        });
        return;
      }

      dispatch(statusAction(composerId, {
        mediaId: media.get('id'),
        reuse: REDRAFT_REUSE_WAITING,
        error: null,
        changingUpload: false,
      }));

      pollRedraftMedia(dispatch, getState, {
        composerId,
        mediaId: media.get('id'),
        epoch,
        attempt: 0,
        startedAt: Date.now(),
      });
    });
  };
}

export function retainRedraftMediaEdits(composerId, mediaId, params) {
  return (dispatch, getState) => {
    const composer = selectComposer(getState(), composerId);
    const media = findMedia(composer, mediaId);

    if (!media || !media.get('redraftReuse')) {
      return;
    }

    const description = Object.prototype.hasOwnProperty.call(params, 'description')
      ? (params.description || '')
      : (media.get('description') || '');

    dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_LOCAL,
      mediaId: media.get('id'),
      description,
      focus: params.focus || focusToken(media),
    }, composerId));

    const updatedComposer = selectComposer(getState(), composerId);
    const updated = findMedia(updatedComposer, media.get('id'));

    if (!updated) {
      return;
    }

    const reuse = updated.get('redraftReuse');

    if (reuse === REDRAFT_REUSE_WAITING) {
      return;
    }

    if (reuse === REDRAFT_REUSE_FAILED && updated.get('redraftError') !== 'save') {
      return;
    }

    saveRedraftMetadata(dispatch, getState, {
      composerId,
      mediaId: updated.get('id'),
      epoch: updatedComposer.get('redraftEpoch'),
    });
  };
}

export function composerRedraftBlocksSubmit(composer) {
  if (!composer) {
    return false;
  }

  const media = composer.get('media_attachments');

  if (!media || media.size === 0) {
    return false;
  }

  return media.some(item => {
    const reuse = item.get('redraftReuse');

    return !!reuse && reuse !== REDRAFT_REUSE_COMPLETE;
  });
}

export function composerRedraftNotice(composer) {
  if (!composer) {
    return null;
  }

  const media = composer.get('media_attachments');

  if (!media || media.size === 0) {
    return null;
  }

  const items = media.filter(item => item.get('redraftReuse'));

  if (!items || items.size === 0) {
    return null;
  }

  if (items.some(item => item.get('redraftReuse') === REDRAFT_REUSE_FAILED && item.get('redraftError') === 'forbidden')) {
    return 'forbidden';
  }

  if (items.some(item => item.get('redraftReuse') === REDRAFT_REUSE_FAILED && item.get('redraftError') === 'prepare')) {
    return 'prepare';
  }

  if (items.some(item => item.get('redraftReuse') === REDRAFT_REUSE_FAILED)) {
    return 'save';
  }

  if (items.some(item => item.get('redraftReuse') === REDRAFT_REUSE_WAITING)) {
    return 'waiting';
  }

  if (items.some(item => item.get('redraftReuse') === REDRAFT_REUSE_SAVING || item.get('redraftReuse') === REDRAFT_REUSE_READY)) {
    return 'saving';
  }

  return null;
}

export const redraftThumbnailWaitingMessage = {
  id: 'upload_modal.thumbnail_waiting',
  defaultMessage: 'You can change the thumbnail after the original post releases this media.',
};

export function rejectThumbnailUntilRedraftReady(composer, mediaId) {
  const media = findMedia(composer, mediaId);
  const reuse = media && media.get('redraftReuse');

  return !!reuse && reuse !== REDRAFT_REUSE_COMPLETE;
}

export function alertThumbnailWaiting() {
  return showAlert(undefined, redraftThumbnailWaitingMessage);
}

export function resetRedraftMediaRuntime() {
  redraftPolls.forEach(timer => clearTimeout(timer));
  redraftPolls.clear();
  redraftSaves.clear();
  redraftResave.clear();
}
