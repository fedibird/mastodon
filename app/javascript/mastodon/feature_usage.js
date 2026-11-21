import initialState from './initial_state_data';

// The booleans describe the signed-in viewer at the moment this document was
// rendered. They are not a cache of what exists later.
//
// - false: the initial prefetch may be skipped.
// - true: prefetch as before. Owning a record does not mean it is enabled.
// - missing, null, or any non-boolean: unknown. Keep the historical prefetch
//   so an older or partial initial state still works, including guests.
//
// Account changes load a new document. Creating or deleting in this tab
// updates the Redux stores directly. Another tab, an explicit open, a retry,
// and a reconnect all go through the unguarded fetchers (fetchCircles,
// fetchLists, loadPersonalEmojiStock). Those must not read this snapshot.
export function featureUsageFlagFrom(state, key) {
  const usage = state && state.feature_usage;

  if (!usage || typeof usage !== 'object' || Array.isArray(usage)) {
    return undefined;
  }

  const value = usage[key];

  return value === true || value === false ? value : undefined;
}

export function featureUsageFlag(key) {
  return featureUsageFlagFrom(initialState, key);
}

export function initialFeaturePrefetchAllowed(flag) {
  return flag !== false;
}
