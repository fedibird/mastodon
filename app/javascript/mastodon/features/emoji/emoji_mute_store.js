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
let notificationFetchEpoch = 0;
let requestVersion = 0;
let sessionVersion = 0;

// A notification list that was cleared, blocked, or filtered must not be
// filled again by a mute refresh that started before that action.
export function invalidateEmojiMuteNotificationFetches() {
  notificationFetchEpoch += 1;
}

export function emojiMuteNotificationFetchEpoch() {
  return notificationFetchEpoch;
}

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

// A resolved empty document is different from a not-yet-fetched document.
// Both the initial display gate and the stream/reaction guards use this.
export function emojiMuteDocumentReady() {
  if (!accessToken && !me) {
    return true;
  }

  return settled && appliedRevision !== null &&
    (observedRevision === null || compareRevision(appliedRevision, observedRevision) >= 0);
}

// Invalidate outstanding GETs before an account boundary is crossed. No
// credential, definition or replacement text is persisted in browser storage.
export function resetEmojiMuteSession() {
  sessionVersion += 1;
  requestVersion += 1;
  observedRevision = null;
  appliedRevision = null;
  mutes = [];
  request = null;
  settled = false;
  invalidateEmojiMuteNotificationFetches();
}

export function emojiReactionEventsAccepted() {
  if (!accessToken && !me) {
    return true;
  }

  return emojiMuteDocumentReady();
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

  // A newer stream revision might arrive after the request was sent. A
  // response below that revision is never an authoritative document.
  if (observedRevision !== null && compareRevision(next, observedRevision) < 0) {
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

  const version = ++requestVersion;
  const session = sessionVersion;
  const pending = api().get('/api/v1/fedibird/emoji_mutes', { headers }).then(response => {
    // Force refresh, session reset, or another user's request superseded us.
    // The old promise may finish, but it must not mutate the module document.
    if (session !== sessionVersion || version !== requestVersion) {
      return mutes;
    }

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
  resetEmojiMuteSession();
  notificationFetchEpoch = 0;
}

export function installEmojiMutesForTests(document) {
  // No pending request from another fixture may overwrite this document.
  requestVersion += 1;
  sessionVersion += 1;
  appliedRevision = String(document.revision);
  observedRevision = appliedRevision;
  mutes = document.emoji_mutes || [];
  request = null;
  settled = true;
}
