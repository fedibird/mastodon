import { acceptedTranslationPreferences } from '../utils/preference_apply';

// `user_preferences.document` is written only after the reducer accepts a
// GET. Reading it here does not handle FETCH_SUCCESS, so a stale response
// that the reducer rejected cannot change translation or appearance.
export const selectAcceptedPreferenceDocument = (state) => {
  if (!state || typeof state.getIn !== 'function') {
    return null;
  }

  return state.getIn(['user_preferences', 'document'], null) || null;
};

export const selectAcceptedTranslationPreferences = (state) => (
  acceptedTranslationPreferences(selectAcceptedPreferenceDocument(state))
);
