// Pending client-document sync after a successful mute/unmute write.
// Survives menu close/reopen so we retry sync only — never re-POST/DELETE.

import { identityKey, normalizeReference } from './reference';

let pendingByKey = new Map();

export function notePendingMuteSync({ reference, revision, mute = null, operation, syncError = null }) {
  const normalized = normalizeReference(reference);
  const key = identityKey(normalized);

  if (!key || !revision || (operation !== 'mute' && operation !== 'unmute')) {
    return null;
  }

  const entry = {
    key,
    reference: normalized,
    revision: String(revision),
    mute: operation === 'mute' ? mute : null,
    operation,
    syncError: syncError || null,
  };

  pendingByKey.set(key, entry);
  return entry;
}

export function clearPendingMuteSync(reference) {
  const key = identityKey(reference);

  if (key) {
    pendingByKey.delete(key);
  }
}

export function getPendingMuteSync(reference) {
  const key = identityKey(reference);

  if (!key) {
    return null;
  }

  return pendingByKey.get(key) || null;
}

export function muteFromPendingOrStore(reference, storeMute) {
  const pending = getPendingMuteSync(reference);

  if (!pending) {
    return storeMute || null;
  }

  if (pending.operation === 'unmute') {
    return null;
  }

  return pending.mute || storeMute || null;
}

export function resetPendingMuteSyncForTests() {
  pendingByKey = new Map();
}
