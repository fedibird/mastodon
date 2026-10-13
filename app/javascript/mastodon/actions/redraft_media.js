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
const REDRAFT_PUT_TIMEOUT_MS = 30_000;

const redraftPolls = new Map();
const redraftDeadlines = new Map();
const redraftRequestTimers = new Set();
const redraftGets = new Map();
const redraftSaves = new Map();
const redraftResave = new Set();

let nextAttemptId = 1;

const generationKey = (composerId, mediaId, generation) => `${composerId}:${mediaId}:${generation}`;

const sameMediaId = (left, right) => String(left) === String(right);

const findMedia = (composer, mediaId) => {
  if (!composer) {
    return null;
  }

  return composer.get('media_attachments').find(item => sameMediaId(item.get('id'), mediaId)) || null;
};

const responseStatus = error => error && error.response && error.response.status;

const requestTimedOut = error => error && error.code === 'ECONNABORTED' && !responseStatus(error);

const requestTimeoutError = () => {
  const error = new Error('timeout');
  error.code = 'ECONNABORTED';
  return error;
};

// Axios timeout is also set on the request. This watchdog still rejects when
// the client promise never settles, so the prepare deadline cannot stall.
const withRequestTimeout = (promise, timeoutMs) => new Promise((resolve, reject) => {
  let settled = false;
  const timer = setTimeout(() => {
    redraftRequestTimers.delete(timer);

    if (settled) {
      return;
    }

    settled = true;
    reject(requestTimeoutError());
  }, timeoutMs);

  redraftRequestTimers.add(timer);

  const finish = (callback, value) => {
    if (settled) {
      return;
    }

    settled = true;
    clearTimeout(timer);
    redraftRequestTimers.delete(timer);
    callback(value);
  };

  return promise.then(value => finish(resolve, value), error => finish(reject, error));
});

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

const keyFor = context => generationKey(context.composerId, context.mediaId, context.generation);

const clearRetryTimer = context => {
  const key = keyFor(context);
  const timer = redraftPolls.get(key);

  if (timer) {
    clearTimeout(timer);
  }

  redraftPolls.delete(key);
};

const clearDeadline = context => {
  const key = keyFor(context);
  const timer = redraftDeadlines.get(key);

  if (timer) {
    clearTimeout(timer);
  }

  redraftDeadlines.delete(key);
};

const clearGeneration = context => {
  const key = keyFor(context);

  clearRetryTimer(context);
  clearDeadline(context);
  redraftGets.delete(key);
};

const statusAction = (composerId, fields) => targetComposerAction({
  type: COMPOSE_REDAFT_MEDIA_STATUS,
  ...fields,
}, composerId);

const composerMatches = (composer, context) => (
  !!composer
  && composer.get('redraftEpoch') === context.epoch
  && composer.get('redraftGeneration') === context.generation
);

const currentComposerMedia = (getState, context) => {
  const composer = selectComposer(getState(), context.composerId);

  if (!composerMatches(composer, context)) {
    return null;
  }

  return findMedia(composer, context.mediaId);
};

const currentWaitingMedia = (getState, context) => {
  const media = currentComposerMedia(getState, context);

  if (!media || media.get('redraftReuse') !== REDRAFT_REUSE_WAITING) {
    return null;
  }

  return media;
};

const failReuse = (dispatch, context, error) => {
  clearGeneration(context);
  dispatch(statusAction(context.composerId, {
    epoch: context.epoch,
    generation: context.generation,
    mediaId: context.mediaId,
    reuse: REDRAFT_REUSE_FAILED,
    error,
    changingUpload: false,
  }));
};

const markComplete = (dispatch, context, media) => {
  dispatch(statusAction(context.composerId, {
    epoch: context.epoch,
    generation: context.generation,
    mediaId: context.mediaId,
    reuse: REDRAFT_REUSE_COMPLETE,
    error: null,
    fetched: true,
    changingUpload: false,
    media,
    keepLocalText: !media,
  }));
};

const beginGet = context => {
  const key = keyFor(context);
  const attemptId = nextAttemptId;

  nextAttemptId += 1;
  redraftGets.set(key, attemptId);
  return attemptId;
};

const getIsCurrent = (context, attemptId) => redraftGets.get(keyFor(context)) === attemptId;

function saveRedraftMetadata(dispatch, getState, context) {
  const key = keyFor(context);
  const composer = selectComposer(getState(), context.composerId);

  if (!composerMatches(composer, context) || composer.get('redraftMediaUnconfirmed')) {
    return;
  }

  const media = findMedia(composer, context.mediaId);

  if (!media || media.get('redraftUnconfirmed')) {
    return;
  }

  const revision = media.get('redraftRevision') || 0;
  const current = redraftSaves.get(key);

  if (current && current.revision === revision) {
    return;
  }

  if (current) {
    redraftResave.add(key);
    return;
  }

  const saveId = nextAttemptId;

  nextAttemptId += 1;
  redraftSaves.set(key, { revision, saveId });
  clearRetryTimer(context);

  dispatch(statusAction(context.composerId, {
    epoch: context.epoch,
    generation: context.generation,
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

  const request = api(getState).put(`/api/v1/media/${media.get('id')}`, params, { timeout: REDRAFT_PUT_TIMEOUT_MS });

  withRequestTimeout(request, REDRAFT_PUT_TIMEOUT_MS).then(response => {
    finishSave(dispatch, getState, context, revision, saveId, response && response.data);
  }).catch(error => {
    finishSaveError(dispatch, getState, context, revision, saveId, error);
  });
}

function finishSave(dispatch, getState, context, revision, saveId, serverMedia) {
  const key = keyFor(context);
  const current = redraftSaves.get(key);

  if (!current || current.saveId !== saveId) {
    return;
  }

  redraftSaves.delete(key);

  const media = currentComposerMedia(getState, context);

  if (!media) {
    redraftResave.delete(key);
    return;
  }

  if ((media.get('redraftRevision') || 0) !== revision || redraftResave.has(key)) {
    redraftResave.delete(key);
    saveRedraftMetadata(dispatch, getState, context);
    return;
  }

  if (!metadataMatches(media, serverMedia)) {
    failReuse(dispatch, context, 'save');
    return;
  }

  markComplete(dispatch, context, null);
}

function finishSaveError(dispatch, getState, context, revision, saveId, error) {
  const key = keyFor(context);
  const current = redraftSaves.get(key);

  if (!current || current.saveId !== saveId) {
    return;
  }

  redraftSaves.delete(key);

  const media = currentComposerMedia(getState, context);

  if (!media) {
    redraftResave.delete(key);
    return;
  }

  if ((media.get('redraftRevision') || 0) !== revision || redraftResave.has(key)) {
    redraftResave.delete(key);
    saveRedraftMetadata(dispatch, getState, context);
    return;
  }

  if (requestTimedOut(error)) {
    failReuse(dispatch, context, 'save');
    return;
  }

  const status = responseStatus(error);

  if (status === 404) {
    dispatch(statusAction(context.composerId, {
      epoch: context.epoch,
      generation: context.generation,
      mediaId: media.get('id'),
      reuse: REDRAFT_REUSE_WAITING,
      error: null,
      changingUpload: false,
      expectedRevision: revision,
    }));
    pollRedraftMedia(dispatch, getState, {
      ...context,
      attempt: 0,
      startedAt: context.startedAt || Date.now(),
    });
    return;
  }

  failReuse(
    dispatch,
    context,
    status === 403 || status === 401 ? 'forbidden' : 'save',
  );
}

function acceptReady(dispatch, getState, context, serverMedia) {
  clearRetryTimer(context);
  clearDeadline(context);

  const media = currentComposerMedia(getState, context);

  if (!media) {
    return;
  }

  const edited = (media.get('redraftRevision') || 0) > 0;

  // Untouched fields stay with the server copy. A stale composer value must not be written back.
  if (!edited) {
    dispatch(statusAction(context.composerId, {
      epoch: context.epoch,
      generation: context.generation,
      mediaId: context.mediaId,
      reuse: REDRAFT_REUSE_COMPLETE,
      error: null,
      fetched: true,
      changingUpload: false,
      media: serverMedia,
      keepLocalText: false,
    }));
    return;
  }

  dispatch(statusAction(context.composerId, {
    epoch: context.epoch,
    generation: context.generation,
    mediaId: context.mediaId,
    reuse: REDRAFT_REUSE_READY,
    error: null,
    fetched: true,
    media: serverMedia,
    keepLocalText: true,
  }));

  const updated = currentComposerMedia(getState, context);

  if (!updated) {
    return;
  }

  if (metadataMatches(updated, serverMedia)) {
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

  const key = keyFor(context);

  clearRetryTimer(context);

  const timer = setTimeout(() => {
    redraftPolls.delete(key);
    pollRedraftMedia(dispatch, getState, { ...context, attempt: context.attempt + 1 });
  }, delay);

  redraftPolls.set(key, timer);
}

function armDeadline(dispatch, getState, context) {
  const key = keyFor(context);

  if (redraftDeadlines.has(key)) {
    return;
  }

  const delay = Math.max(0, context.startedAt + REDRAFT_POLL_LIMIT_MS - Date.now());
  const timer = setTimeout(() => {
    redraftDeadlines.delete(key);
    redraftGets.delete(key);

    if (!currentWaitingMedia(getState, context)) {
      return;
    }

    failReuse(dispatch, context, 'prepare');
  }, delay);

  redraftDeadlines.set(key, timer);
}

function pollRedraftMedia(dispatch, getState, context) {
  if (Date.now() - context.startedAt > REDRAFT_POLL_LIMIT_MS) {
    failReuse(dispatch, context, 'prepare');
    return;
  }

  if (!currentWaitingMedia(getState, context)) {
    clearRetryTimer(context);
    return;
  }

  armDeadline(dispatch, getState, context);

  const attemptId = beginGet(context);
  const remaining = Math.max(1, context.startedAt + REDRAFT_POLL_LIMIT_MS - Date.now());
  const request = api(getState).get(`/api/v1/media/${context.mediaId}`, { timeout: remaining });

  withRequestTimeout(request, remaining).then(response => {
    if (!getIsCurrent(context, attemptId)) {
      return;
    }

    redraftGets.delete(keyFor(context));

    if (!currentWaitingMedia(getState, context)) {
      clearRetryTimer(context);
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
    if (!getIsCurrent(context, attemptId)) {
      return;
    }

    redraftGets.delete(keyFor(context));

    if (!currentWaitingMedia(getState, context)) {
      clearRetryTimer(context);
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

    if (composer.get('redraftMediaUnconfirmed')) {
      return;
    }

    const epoch = composer.get('redraftEpoch');
    const generation = composer.get('redraftGeneration');
    const startedAt = Date.now();

    composer.get('media_attachments').forEach(media => {
      if (media.get('redraftReuse') !== REDRAFT_REUSE_WAITING || media.get('redraftUnconfirmed')) {
        return;
      }

      pollRedraftMedia(dispatch, getState, {
        composerId,
        mediaId: media.get('id'),
        epoch,
        generation,
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

    if (composer.get('redraftMediaUnconfirmed')) {
      return;
    }

    const epoch = composer.get('redraftEpoch');
    const generation = composer.get('redraftGeneration');

    composer.get('media_attachments').forEach(media => {
      if (media.get('redraftReuse') !== REDRAFT_REUSE_FAILED || media.get('redraftUnconfirmed')) {
        return;
      }

      if (media.get('redraftFetched') === true && media.get('redraftError') === 'save') {
        saveRedraftMetadata(dispatch, getState, {
          composerId,
          mediaId: media.get('id'),
          epoch,
          generation,
        });
        return;
      }

      dispatch(statusAction(composerId, {
        epoch,
        generation,
        mediaId: media.get('id'),
        reuse: REDRAFT_REUSE_WAITING,
        error: null,
        changingUpload: false,
      }));

      pollRedraftMedia(dispatch, getState, {
        composerId,
        mediaId: media.get('id'),
        epoch,
        generation,
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

    if (!media || !media.get('redraftReuse') || media.get('redraftUnconfirmed') || composer.get('redraftMediaUnconfirmed')) {
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
      epoch: composer.get('redraftEpoch'),
      generation: composer.get('redraftGeneration'),
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
      generation: updatedComposer.get('redraftGeneration'),
    });
  };
}

export function composerRedraftBlocksSubmit(composer) {
  if (!composer) {
    return false;
  }

  if (composer.get('redraftMediaUnconfirmed')) {
    return true;
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

  if (composer.get('redraftMediaUnconfirmed')) {
    return 'prepare';
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
  redraftDeadlines.forEach(timer => clearTimeout(timer));
  redraftDeadlines.clear();
  redraftRequestTimers.forEach(timer => clearTimeout(timer));
  redraftRequestTimers.clear();
  redraftGets.clear();
  redraftSaves.clear();
  redraftResave.clear();
  nextAttemptId = 1;
}
