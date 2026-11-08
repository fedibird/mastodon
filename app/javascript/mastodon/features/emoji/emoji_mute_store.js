import api from 'mastodon/api';
import initialState from 'mastodon/initial_state_data';

// Memory only. A mute definition, replacement, or access token must not be
// written to localStorage. A late response older than the known revision is
// ignored.

let revision = null;
let mutes = [];
let request = null;
let settled = false;

const me = initialState?.meta?.me;
const accessToken = initialState?.meta?.access_token;

export function currentEmojiMuteRevision() {
  return revision;
}

export function currentEmojiMutes() {
  return mutes;
}

export function emojiReactionEventsAccepted() {
  return !accessToken || settled;
}

function adopt(document, minRevision) {
  if (!document || !Array.isArray(document.emoji_mutes) || !Number.isInteger(document.revision)) {
    throw new Error('Invalid emoji mute document');
  }

  if (revision !== null && document.revision < revision) {
    return mutes;
  }

  if (minRevision !== null && minRevision !== undefined && document.revision < minRevision) {
    return mutes;
  }

  revision = document.revision;
  mutes = document.emoji_mutes;
  settled = true;
  return mutes;
}

export function loadEmojiMutes(options = {}) {
  if (!accessToken && !me) {
    settled = true;
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
  }).catch(error => {
    settled = true;
    throw error;
  }).finally(() => {
    if (request === pending) {
      request = null;
    }
  });

  request = pending;
  return pending;
}

export function noteEmojiMutesChanged(payload) {
  const next = Number(payload && payload.revision);
  if (!Number.isInteger(next) || (revision !== null && next <= revision)) {
    return Promise.resolve(mutes);
  }

  return loadEmojiMutes({ force: true, minRevision: next });
}

export function keepFreshReactions(status, previous) {
  if (!status || typeof status !== 'object') {
    return;
  }

  const snapshot = status.emoji_mutes_revision;
  delete status.emoji_mutes_revision;

  if (snapshotIsCurrent(snapshot) || !previous || typeof previous.get !== 'function') {
    return;
  }

  const previousReactions = previous.get('emoji_reactions');
  if (previousReactions === null || previousReactions === undefined || typeof previousReactions.toJS !== 'function') {
    return;
  }

  status.emoji_reactions = previousReactions.toJS();
  const previousCount = previous.get('emoji_reactions_count');
  if (previousCount !== null && previousCount !== undefined) {
    status.emoji_reactions_count = previousCount;
  }
}

function snapshotIsCurrent(snapshot) {
  if (snapshot === null || snapshot === undefined || revision === null) {
    return true;
  }

  return Number(snapshot) >= revision;
}
