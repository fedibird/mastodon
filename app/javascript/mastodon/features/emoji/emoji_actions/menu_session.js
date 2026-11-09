import { referencesEqual } from './reference';

// A mute/unmute/category mutation started for one menu must not paint into a
// later menu that opened for a different emoji (or a newer generation).
export function isCurrentMenuSession(session, { loadGeneration, reference }) {
  if (!session || session.generation !== loadGeneration) {
    return false;
  }

  return referencesEqual(session.reference, reference);
}

// Flight completions may land after close→reopen of the *same* identity.
// Apply UI updates when the open menu matches the started reference, even if
// loadGeneration advanced. Never apply into a different emoji's menu.
export function canApplyMutationToOpenMenu(session, { reference: openReference }) {
  if (!session || !openReference) {
    return false;
  }

  return referencesEqual(session.reference, openReference);
}

export function captureMenuSession(loadGeneration, reference) {
  return {
    generation: loadGeneration,
    reference,
  };
}
