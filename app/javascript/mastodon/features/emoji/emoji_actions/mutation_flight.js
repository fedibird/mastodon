// In-flight mute/unmute writes keyed by stable identity. Survives menu
// close/reopen so a deferred POST/DELETE cannot be started twice.

import { identityKey, normalizeReference } from './reference';

let flightsByKey = new Map();

export function beginMuteMutation(reference, operation) {
  const normalized = normalizeReference(reference);
  const key = identityKey(normalized);

  if (!key || (operation !== 'mute' && operation !== 'unmute')) {
    return false;
  }

  if (flightsByKey.has(key)) {
    return false;
  }

  flightsByKey.set(key, {
    key,
    reference: normalized,
    operation,
    startedAt: Date.now(),
  });

  return true;
}

export function endMuteMutation(reference) {
  const key = identityKey(reference);

  if (key) {
    flightsByKey.delete(key);
  }
}

export function getMuteMutationFlight(reference) {
  const key = identityKey(reference);

  if (!key) {
    return null;
  }

  return flightsByKey.get(key) || null;
}

export function isMuteMutationInFlight(reference) {
  return Boolean(getMuteMutationFlight(reference));
}

export function resetMuteMutationFlightsForTests() {
  flightsByKey = new Map();
}
