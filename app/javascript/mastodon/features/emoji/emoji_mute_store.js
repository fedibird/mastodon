import api from 'mastodon/api';
import initialState from 'mastodon/initial_state_data';

// Memory only. The definition, replacement text, and access token are not
// written to localStorage. `observedRevision` is the newest change we have
// seen. `appliedRevision` is the document actually stored. Reaction events
// wait until the applied document has caught up.

const REVISION = /^(?:0|[1-9]\d*)$/;

let observedRevision = null;
let appliedRevision = null;
let mutes = [];
let request = null;
let settled = false;

const me = initialState?.meta?.me;
const accessToken = initialState?.meta?.access_token;

export function compareRevision(left, right) {
  const a = String(left);
  const b = String(right);

  if (a === b) {
    return 0;
  }

  if (a.length === b.length) {
    return a > b ? 1 : -1;
  }

  return a.length > b.length ? 1 : -1;
}

export function currentEmojiMutes() {
  return mutes;
}

export function appliedEmojiMuteRevision() {
  return appliedRevision;
}

export function observedEmojiMuteRevision() {
  return observedRevision;
}

export function emojiReactionEventsAccepted() {
  if (!accessToken && !me) {
    return true;
  }

  return settled && appliedRevision !== null && (observedRevision === null || compareRevision(appliedRevision, observedRevision) >= 0);
}

function adopt(document, minRevision) {
  if (!document || !Array.isArray(document.emoji_mutes) || !REVISION.test(String(document.revision))) {
    throw new Error('Invalid emoji mute document');
  }

  const next = String(document.revision);

  if (appliedRevision !== null && compareRevision(next, appliedRevision) < 0) {
    return mutes;
  }

  if (minRevision !== null && minRevision !== undefined && compareRevision(next, String(minRevision)) < 0) {
    return mutes;
  }

  appliedRevision = next;
  mutes = document.emoji_mutes;

  if (observedRevision === null || compareRevision(appliedRevision, observedRevision) >= 0) {
    observedRevision = appliedRevision;
    settled = true;
  }

  return mutes;
}

export function loadEmojiMutes(options = {}) {
  if (!accessToken && !me) {
    settled = true;
    appliedRevision = appliedRevision || '0';
    return Promise.resolve(mutes);
  }

  if (request && !options.force) {
    return request;
  }

  const headers = {};

  if (accessToken) {
    headers.Authorization = `Bearer ${accessToken}`;
  }

  const pending = api().get('/api/v1/fedibird/emoji_mutes', { headers }).then(response => {
    return adopt(response.data, options.minRevision);
  }).finally(() => {
    if (request === pending) {
      request = null;
    }
  });

  request = pending;
  return pending;
}

export function noteEmojiMutesChanged(payload) {
  const next = payload && payload.revision !== undefined && payload.revision !== null ? String(payload.revision) : '';

  if (!REVISION.test(next)) {
    return Promise.resolve(mutes);
  }

  if (observedRevision === null || compareRevision(next, observedRevision) > 0) {
    observedRevision = next;
    settled = false;
  }

  if (appliedRevision !== null && compareRevision(appliedRevision, observedRevision) >= 0) {
    settled = true;
    return Promise.resolve(mutes);
  }

  return loadEmojiMutes({ force: true, minRevision: observedRevision });
}

export function resetEmojiMuteStoreForTests() {
  observedRevision = null;
  appliedRevision = null;
  mutes = [];
  request = null;
  settled = false;
}

export function installEmojiMutesForTests(document) {
  appliedRevision = String(document.revision);
  observedRevision = appliedRevision;
  mutes = document.emoji_mutes || [];
  request = null;
  settled = true;
}
