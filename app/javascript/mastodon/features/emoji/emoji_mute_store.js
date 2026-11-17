import api from 'mastodon/api';
import initialState from 'mastodon/initial_state_data';

// Memory only. The definition, replacement text, and access token are not
// written to localStorage. `observedRevision` is the newest change we have
// seen. `appliedRevision` is the document actually stored. Reaction events
// wait until the applied document has caught up.

const REVISION = /^(?:0|[1-9]\d*)$/;
// Axios has no request timeout by default. A stalled request must release
// the initial/stream revision gate to a retryable error state.
const EMOJI_MUTES_GET_TIMEOUT_MS = 20000;

let observedRevision = null;
let appliedRevision = null;
let mutes = [];
let request = null;
let settled = false;
let notificationFetchEpoch = 0;
let requestVersion = 0;
let sessionVersion = 0;
// 401/403 are not cleared by a repeated stream event for the revision we
// already hold. Only a GET that adopts a current document lifts this.
let authorizationFailure = null;
let viewerSignedInOverride = null;
const documentListeners = new Set();

function viewerIsSignedIn() {
  if (viewerSignedInOverride !== null) {
    return viewerSignedInOverride;
  }

  return Boolean(accessToken || me);
}

function notifyEmojiMuteDocument() {
  documentListeners.forEach(listener => {
    try {
      listener();
    } catch (error) {
      // A picker subscriber must not block document adoption.
    }
  });
}

export function subscribeEmojiMuteDocument(listener) {
  documentListeners.add(listener);

  return () => {
    documentListeners.delete(listener);
  };
}

// Tests simulate a signed-in viewer without boot JSON. Production leaves this
// unset and uses the page's account metadata.
export function setEmojiMuteViewerSignedInForTests(signedIn) {
  viewerSignedInOverride = signedIn === null || signedIn === undefined ? null : Boolean(signedIn);
  notifyEmojiMuteDocument();
}

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
export function emojiMuteAuthorizationFailure() {
  return authorizationFailure;
}

export function blockEmojiMuteAuthorization(failure) {
  authorizationFailure = failure === 'forbidden' ? 'forbidden' : 'unauthorized';
  notifyEmojiMuteDocument();
}

export function emojiMuteDocumentReady() {
  if (authorizationFailure) {
    return false;
  }

  if (!viewerIsSignedIn()) {
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
  authorizationFailure = null;
  invalidateEmojiMuteNotificationFetches();
  notifyEmojiMuteDocument();
}

export function emojiReactionEventsAccepted() {
  if (!viewerIsSignedIn()) {
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
    authorizationFailure = null;
  }

  notifyEmojiMuteDocument();
  return mutes;
}

export function loadEmojiMutes(options = {}) {
  if (!viewerIsSignedIn()) {
    const changed = !settled || appliedRevision === null;
    settled = true;
    appliedRevision = appliedRevision || '0';

    if (changed) {
      notifyEmojiMuteDocument();
    }

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
  const pending = api().get('/api/v1/fedibird/emoji_mutes', { headers, timeout: EMOJI_MUTES_GET_TIMEOUT_MS }).then(response => {
    // Force refresh, session reset, or another user's request superseded us.
    // The old promise may finish, but it must not mutate the module document.
    if (session !== sessionVersion || version !== requestVersion) {
      return mutes;
    }

    if (options.strict && appliedRevision !== null &&
        (!response.data || !REVISION.test(String(response.data.revision)) ||
         compareRevision(String(response.data.revision), appliedRevision) < 0)) {
      throw new Error('Emoji mute revision did not reach the verified version');
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

  let changed = false;

  if (observedRevision === null || compareRevision(next, observedRevision) > 0) {
    observedRevision = next;
    settled = false;
    changed = true;
  }

  if (appliedRevision !== null && compareRevision(appliedRevision, observedRevision) >= 0) {
    if (!settled) {
      changed = true;
    }

    settled = true;

    if (changed) {
      notifyEmojiMuteDocument();
    }

    return Promise.resolve(mutes);
  }

  if (changed) {
    notifyEmojiMuteDocument();
  }

  return loadEmojiMutes({ force: true, minRevision: observedRevision });
}

export function resetEmojiMuteStoreForTests() {
  viewerSignedInOverride = null;
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
  authorizationFailure = null;
  notifyEmojiMuteDocument();
}
