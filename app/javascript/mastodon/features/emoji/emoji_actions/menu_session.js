import { referencesEqual } from './reference';

// A mute/unmute/category mutation started for one menu must not paint into a
// later menu that opened for a different emoji (or a newer generation).
export function isCurrentMenuSession(session, { loadGeneration, reference }) {
  if (!session || session.generation !== loadGeneration) {
    return false;
  }

  return referencesEqual(session.reference, reference);
}

export function captureMenuSession(loadGeneration, reference) {
  return {
    generation: loadGeneration,
    reference,
  };
}
