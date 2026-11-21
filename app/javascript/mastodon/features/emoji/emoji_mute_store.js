import api from 'mastodon/api';
import initialState from 'mastodon/initial_state_data';
import { emojiMuteBypassEnabled } from './emoji_mute_boot_bypass';
import {
  currentEmojiMuteBoot,
  noteEmojiMuteDisabledLocally,
  noteEmojiMuteEnabledLocally,
  resetEmojiMuteBootForTests,
} from './emoji_mute_availability';

// Memory only. The definition, replacement text, and access token are not
// written to localStorage. `observedRevision` is the newest change we have
// seen. `appliedRevision` is the document actually stored. Reaction events
// wait until the applied document has caught up.

const REVISION = /^(?:0|[1-9]\d*)$/;
// Axios has no request timeout by default. A stalled request must release
// the initial/stream revision gate to a retryable error state.
const EMOJI_MUTES_GET_TIMEOUT_MS = 20000;
const EMOJI_MUTE_PREFERENCE_TIMEOUT_MS = 20000;

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
let temporaryIgnore = false;
let preferenceConfirming = false;
let preferenceConfirmGeneration = 0;
const documentListeners = new Set();

function rulesFetchSkipped() {
  return emojiMuteBypassEnabled() || temporaryIgnore || currentEmojiMuteBoot().availability === 'disabled';
}

export function emojiMuteTemporarilyIgnored() {
  return temporaryIgnore;
}

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
  // Reconnect confirmation has already hidden emoji in Redux. The module
  // must not keep accepting reactions from the previous OFF snapshot.
  if (preferenceConfirming) {
    return false;
  }

  if (rulesFetchSkipped()) {
    return true;
  }

  if (authorizationFailure) {
    return false;
  }

  if (!viewerIsSignedIn()) {
    return true;
  }

  return settled && appliedRevision !== null &&
    (observedRevision === null || compareRevision(appliedRevision, observedRevision) >= 0);
}

function releaseEmojiMutePreferenceConfirmation() {
  preferenceConfirmGeneration += 1;
  preferenceConfirming = false;
}

export function beginEmojiMutePreferenceConfirmation() {
  preferenceConfirming = true;
  preferenceConfirmGeneration += 1;
  requestVersion += 1;
  request = null;
  settled = false;
  notifyEmojiMuteDocument();
  return preferenceConfirmGeneration;
}

export function emojiMutePreferenceConfirmationCurrent(generation) {
  return generation === preferenceConfirmGeneration;
}

export function endEmojiMutePreferenceConfirmation(generation) {
  if (generation !== preferenceConfirmGeneration) {
    return false;
  }

  releaseEmojiMutePreferenceConfirmation();
  notifyEmojiMuteDocument();
  return true;
}

// Invalidate outstanding GETs before an account boundary is crossed. No
// credential, definition or replacement text is persisted in browser storage.
export function resetEmojiMuteSession() {
  sessionVersion += 1;
  requestVersion += 1;
  appliedPreferenceRevision = '0';
  releaseEmojiMutePreferenceConfirmation();
  beginEmojiMutePreferenceRead();
  observedRevision = null;
  appliedRevision = null;
  mutes = [];
  request = null;
  settled = false;
  authorizationFailure = null;
  temporaryIgnore = false;
  invalidateEmojiMuteNotificationFetches();
  notifyEmojiMuteDocument();
}

export function beginEmojiMuteEnabledFetch() {
  noteEmojiMuteEnabledLocally();
  releaseEmojiMutePreferenceConfirmation();
  beginEmojiMutePreferenceRead();
  temporaryIgnore = false;
  requestVersion += 1;
  request = null;
  settled = false;
  appliedRevision = null;
  mutes = [];
  authorizationFailure = null;
  notifyEmojiMuteDocument();
}

export function applyEmojiMuteDisabledDocument() {
  noteEmojiMuteDisabledLocally();
  releaseEmojiMutePreferenceConfirmation();
  beginEmojiMutePreferenceRead();
  temporaryIgnore = false;
  requestVersion += 1;
  request = null;
  settled = true;
  appliedRevision = appliedRevision || '0';
  observedRevision = appliedRevision;
  mutes = [];
  authorizationFailure = null;
  notifyEmojiMuteDocument();
}

export function ignoreEmojiMutesForThisView() {
  temporaryIgnore = true;
  releaseEmojiMutePreferenceConfirmation();
  requestVersion += 1;
  request = null;
  settled = true;
  appliedRevision = appliedRevision || '0';
  observedRevision = appliedRevision;
  mutes = [];
  authorizationFailure = null;
  notifyEmojiMuteDocument();
}

export function clearEmojiMuteTemporaryIgnore() {
  if (!temporaryIgnore) {
    return;
  }

  temporaryIgnore = false;
  settled = false;
  appliedRevision = null;
  mutes = [];
  notifyEmojiMuteDocument();
}

export function emojiReactionEventsAccepted() {
  if (!viewerIsSignedIn()) {
    return true;
  }

  return emojiMuteDocumentReady();
}

// The mute list uses Preference#as_json (`enabled`). Older create responses
// used `emoji_mute_enabled`. Only a strict false turns effects off; a missing
// field still applies the rules.
function documentPreference(document) {
  if (!document || typeof document !== 'object') {
    return null;
  }

  if (document.enabled === true || document.enabled === false) {
    return document.enabled;
  }

  if (document.emoji_mute_enabled === true || document.emoji_mute_enabled === false) {
    return document.emoji_mute_enabled;
  }

  return null;
}

function adopt(document, minRevision, preferenceGeneration) {
  if (!document || !Array.isArray(document.emoji_mutes) || !REVISION.test(String(document.revision))) {
    throw new Error('Invalid emoji mute document');
  }

  const next = String(document.revision);
  const preference = documentPreference(document);

  // An older list must not turn the feature on or off after a newer list.
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

  if (preference === false) {
    // A preference read that started after this list owns the outcome.
    // Adopting this snapshot would also invalidate that newer read.
    if (preferenceGeneration !== preferenceReadGeneration) {
      return mutes;
    }

    applyEmojiMuteDisabledDocument();
    appliedRevision = next;
    observedRevision = next;
    notifyEmojiMuteDocument();
    return mutes;
  }

  if (preference === true && currentEmojiMuteBoot().availability !== 'enabled') {
    noteEmojiMuteEnabledLocally();
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
  if (rulesFetchSkipped()) {
    const changed = !settled || appliedRevision === null;
    settled = true;
    appliedRevision = appliedRevision || '0';
    if (emojiMuteBypassEnabled() || temporaryIgnore || currentEmojiMuteBoot().availability === 'disabled') {
      mutes = [];
    }

    if (changed) {
      notifyEmojiMuteDocument();
    }

    return Promise.resolve(mutes);
  }

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
  const preferenceGeneration = preferenceReadGeneration;
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

    return adopt(response.data, options.minRevision, preferenceGeneration);
  }).finally(() => {
    if (request === pending) {
      request = null;
    }
  });

  request = pending;
  return pending;
}

export function noteEmojiMutesChanged(payload) {
  if (preferenceConfirming || rulesFetchSkipped()) {
    return Promise.resolve(mutes);
  }

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
  temporaryIgnore = false;
  preferenceReadGeneration = 0;
  appliedPreferenceRevision = '0';
  resetEmojiMuteBootForTests();
  resetEmojiMuteSession();
  notificationFetchEpoch = 0;
}

let preferenceReadGeneration = 0;
let appliedPreferenceRevision = '0';

export function emojiMuteRequestVersion() {
  return requestVersion;
}

export function emojiMutePreferenceGeneration() {
  return preferenceReadGeneration;
}

export function beginEmojiMutePreferenceRead() {
  preferenceReadGeneration += 1;
  return preferenceReadGeneration;
}

export function emojiMutePreferenceReadCurrent(generation) {
  return generation === preferenceReadGeneration;
}

export function preferenceRevisionStale(revision) {
  if (revision === undefined || revision === null || revision === '') {
    return false;
  }

  return compareRevision(String(revision), appliedPreferenceRevision) < 0;
}

export function notePreferenceRevision(revision) {
  if (revision === undefined || revision === null || revision === '') {
    return;
  }

  const next = String(revision);

  if (compareRevision(next, appliedPreferenceRevision) > 0) {
    appliedPreferenceRevision = next;
  }
}

function acceptablePreference(data) {
  return !!(data && data.explicit === true && (data.enabled === true || data.enabled === false));
}

function applySavedPreference(data) {
  notePreferenceRevision(data.preference_revision);

  if (data.enabled === false) {
    applyEmojiMuteDisabledDocument();
  } else {
    beginEmojiMuteEnabledFetch();
  }

  return { ...data, applied: true };
}

function preferenceResponseLost(error) {
  const code = error && error.response && error.response.data && Array.isArray(error.response.data.errors)
    ? error.response.data.errors[0] && error.response.data.errors[0].code
    : null;

  if (code === 'not_saved') {
    return true;
  }

  return !error || !error.response;
}

export function loadEmojiMutePreference() {
  const headers = {};

  if (accessToken) {
    headers.Authorization = `Bearer ${accessToken}`;
  }

  return api().get('/api/v1/fedibird/emoji_mute_preference', { headers, timeout: EMOJI_MUTE_PREFERENCE_TIMEOUT_MS }).then(response => (
    response && response.data
  ));
}

function confirmSavedPreference(generation) {
  return loadEmojiMutePreference().then(data => {
    if (!acceptablePreference(data)) {
      throw new Error('Emoji mute preference was not saved');
    }

    if (!emojiMutePreferenceReadCurrent(generation) || preferenceRevisionStale(data.preference_revision)) {
      return { ...data, applied: false };
    }

    return applySavedPreference(data);
  });
}

export function saveEmojiMuteEnabled(enabled) {
  const headers = { 'Content-Type': 'application/json' };
  const generation = preferenceReadGeneration;

  if (accessToken) {
    headers.Authorization = `Bearer ${accessToken}`;
  }

  return api().patch('/api/v1/fedibird/emoji_mute_preference', { enabled }, { headers, timeout: EMOJI_MUTE_PREFERENCE_TIMEOUT_MS }).then(response => {
    const data = response && response.data;

    if (!acceptablePreference(data)) {
      throw new Error('Emoji mute preference was not saved');
    }

    if (!emojiMutePreferenceReadCurrent(generation) || preferenceRevisionStale(data.preference_revision)) {
      return confirmSavedPreference(generation);
    }

    return applySavedPreference(data);
  }).catch(error => {
    if (!preferenceResponseLost(error)) {
      throw error;
    }

    return confirmSavedPreference(generation);
  });
}

export function installEmojiMutesForTests(document) {
  // No pending request from another fixture may overwrite this document.
  releaseEmojiMutePreferenceConfirmation();
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
