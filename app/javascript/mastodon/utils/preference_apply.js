// Public values from an accepted preference document.
// `configured` is never applied. A missing or invalid key is skipped so the
// other keys can still apply. `undefined` means "do not touch this key";
// `null` is a real public value for the derived posting language.

const SELECTABLE_PRIVACIES = new Set(['public', 'unlisted', 'private', 'mutual', 'personal']);
const TRANSLATION_BAR_VISIBILITIES = new Set(['always', 'target', 'never']);
const TRANSLATION_PREFERRED_MODES = new Set(['translated', 'bilingual', 'both']);
const FEATURE_POLICIES = new Set(['conservative', 'default', 'tester']);

const isBoolean = value => value === true || value === false;

const isSelectablePrivacy = value => typeof value === 'string' && SELECTABLE_PRIVACIES.has(value);

const isPostingLanguage = value => (
  value === null || (typeof value === 'string' && value.trim() !== '')
);

const isTranslationVisibility = value => typeof value === 'string' && TRANSLATION_BAR_VISIBILITIES.has(value);

const isTranslationMode = value => typeof value === 'string' && TRANSLATION_PREFERRED_MODES.has(value);

const isFeaturePolicy = value => typeof value === 'string' && FEATURE_POLICIES.has(value);

const preferenceEntry = (document, key) => {
  if (!document || typeof document !== 'object' || Array.isArray(document)) {
    return null;
  }

  const preferences = document.preferences;

  if (!preferences || typeof preferences !== 'object' || Array.isArray(preferences)) {
    return null;
  }

  const entry = preferences[key];

  if (!entry || typeof entry !== 'object' || Array.isArray(entry) || entry.public_valid !== true) {
    return null;
  }

  if (entry.key !== undefined && entry.key !== key) {
    return null;
  }

  return entry;
};

export const acceptedPublicValue = (document, key, accept) => {
  const entry = preferenceEntry(document, key);

  if (!entry || !accept(entry.public_value)) {
    return undefined;
  }

  return entry.public_value;
};

// Ruby TranslationPreferences.default_visibility. Used only when the bar's
// own public value cannot be applied. An explicit public bar value wins.
export const defaultTranslationBarVisibility = (policy) => {
  if (policy === 'conservative') {
    return 'never';
  }

  if (policy === 'tester') {
    return 'always';
  }

  if (policy === 'default') {
    return 'target';
  }

  return null;
};

export const acceptedTranslationPreferences = (document) => {
  if (!document) {
    return { visibility: null, preferredMode: null };
  }

  const bar = acceptedPublicValue(document, 'user.show_translation_bar', isTranslationVisibility);
  const policy = acceptedPublicValue(document, 'user.new_features_policy', isFeaturePolicy);
  let visibility = null;

  if (bar !== undefined) {
    visibility = bar;
  } else if (policy !== undefined) {
    visibility = defaultTranslationBarVisibility(policy);
  }

  const preferredMode = acceptedPublicValue(document, 'user.translation_preferred_mode', isTranslationMode);

  return {
    visibility,
    preferredMode: preferredMode === undefined ? null : preferredMode,
  };
};

const collectionSize = (value) => (
  value && typeof value.size === 'number' ? value.size : 0
);

const textOf = (value) => (typeof value === 'string' ? value.trim() : '');

const rawText = (value) => (typeof value === 'string' ? value : '');

const composerHasUploadWork = (state) => (
  (state.get('pending_media_attachments') || 0) > 0 ||
  (state.get('pending_exclusive_attachments') || 0) > 0 ||
  (state.get('processing_media_attachments') || 0) > 0 ||
  state.get('is_uploading') === true ||
  state.get('is_processing') === true ||
  state.get('is_submitting') === true ||
  state.get('is_changing_upload') === true ||
  state.get('isUploadingThumbnail') === true
);

const composerHasStructuralDraft = (state) => (
  state.get('spoiler') === true ||
  collectionSize(state.get('media_attachments')) > 0 ||
  composerHasUploadWork(state) ||
  !!state.get('poll') ||
  !!state.get('in_reply_to') ||
  !!state.get('quote_from') ||
  !!state.get('id') ||
  !!state.get('scheduled') ||
  !!state.get('scheduled_status_id') ||
  collectionSize(state.get('references')) > 0 ||
  collectionSize(state.get('context_references')) > 0 ||
  state.get('redraftMediaUnconfirmed') === true
);

export const composerHasDraftContent = (state) => {
  if (!state || typeof state.get !== 'function') {
    return false;
  }

  return (
    textOf(state.get('text')) !== '' ||
    textOf(state.get('spoiler_text')) !== '' ||
    composerHasStructuralDraft(state)
  );
};

// Reload confirmation is separate from composerCanFollowPreferenceSelection.
// A manual privacy, language, or sensitive change sets dirty with an empty
// body. Whitespace in the body is typed text. An automatic posting context,
// surface, or managed tag from the open timeline is not unsaved work.
export const composerHasUnsavedReloadWork = (state) => {
  if (!state || typeof state.get !== 'function') {
    return false;
  }

  return (
    rawText(state.get('text')) !== '' ||
    rawText(state.get('spoiler_text')) !== '' ||
    state.get('dirty') === true ||
    !!state.get('datetime_form') ||
    !!state.getIn(['media_modal', 'dirty']) ||
    !!state.getIn(['media_modal', 'id']) ||
    composerHasStructuralDraft(state)
  );
};

const composerHasForeignContext = (state) => {
  const senderId = String(state.getIn(['senderIdentity', 'id']) || '');
  const styleStatus = state.getIn(['userPostingStyle', 'status']);

  return (
    state.get('searchability_manual') === true ||
    !!state.get('circle_id') ||
    !!state.get('posting_context_account_id') ||
    !!state.get('draft_audience_account_id') ||
    !!state.getIn(['context', 'key']) ||
    !!state.getIn(['context', 'source']) ||
    collectionSize(state.getIn(['context', 'managed', 'hashtags'])) > 0 ||
    collectionSize(state.getIn(['context', 'managed', 'mentions'])) > 0 ||
    !!state.getIn(['context', 'constraints', 'allowedVisibilities']) ||
    !!state.getIn(['userPostingStyle', 'selectedId']) ||
    collectionSize(state.getIn(['userPostingStyle', 'manualFields'])) > 0 ||
    (!!styleStatus && styleStatus !== 'idle') ||
    !!state.getIn(['userPostingStyle', 'selectionOrigin']) ||
    !!state.get('surface') ||
    !!state.get('pendingSurface') ||
    state.get('surfaceMismatch') === true ||
    senderId.startsWith('delegated:') ||
    state.getIn(['senderIdentity', 'selectionOrigin']) === 'explicit' ||
    !!state.getIn(['media_modal', 'dirty']) ||
    !!state.getIn(['media_modal', 'id'])
  );
};

// Current privacy and language may follow a new default only when the
// composer has no draft and no other identity, style, or destination has
// chosen those fields. `sensitive` is never followed: clearAll stores false
// there, and default_sensitive applies when media is added later.
export const composerCanFollowPreferenceSelection = (state) => {
  if (!state || typeof state.get !== 'function') {
    return false;
  }

  if (state.get('dirty') === true || !!state.get('datetime_form') || composerHasDraftContent(state)) {
    return false;
  }

  return !composerHasForeignContext(state);
};

const selectionStillDefault = (state, field, defaultField) => {
  const current = state.get(field);

  return current === state.get(defaultField) || current === null || current === undefined;
};

export const applyComposerPreferenceDefaults = (state, document) => {
  if (!state || typeof state.withMutations !== 'function') {
    return state;
  }

  const privacy = acceptedPublicValue(document, 'user.default_privacy', isSelectablePrivacy);
  const sensitive = acceptedPublicValue(document, 'user.default_sensitive', isBoolean);
  const language = acceptedPublicValue(document, 'user.preferred_posting_language', isPostingLanguage);
  const follow = composerCanFollowPreferenceSelection(state);
  const privacyFollows = follow && privacy !== undefined && selectionStillDefault(state, 'privacy', 'default_privacy');
  const languageFollows = follow && language !== undefined && selectionStillDefault(state, 'language', 'default_language');

  return state.withMutations(map => {
    if (privacy !== undefined) {
      map.set('default_privacy', privacy);
    }

    if (sensitive !== undefined) {
      map.set('default_sensitive', sensitive);
    }

    if (language !== undefined) {
      map.set('default_language', language);
    }

    if (privacyFollows) {
      map.set('privacy', privacy);
    }

    if (languageFollows) {
      map.set('language', language);
    }
  });
};

export const fontSizeBaseline = (value) => {
  if (typeof value === 'number' && Number.isInteger(value)) {
    return value;
  }

  if (typeof value === 'string' && /^-?\d+$/.test(value)) {
    return Number(value);
  }

  return undefined;
};

export const motionBaseline = (value) => (
  typeof value === 'boolean' ? value : undefined
);

const baselinePresent = (value) => value !== undefined && value !== null;

export const preferenceBaseline = (state, metaKey, moduleValue) => {
  if (baselinePresent(moduleValue)) {
    return moduleValue;
  }

  if (state && typeof state.hasIn === 'function' && state.hasIn(['meta', metaKey])) {
    const stored = state.getIn(['meta', metaKey]);

    if (baselinePresent(stored)) {
      return stored;
    }
  }

  return undefined;
};

export const reloadPreferenceChanged = (document, baselines = {}) => {
  if (!document) {
    return false;
  }

  const fonts = [
    ['user.content_font_size', baselines.contentFontSize],
    ['user.info_font_size', baselines.infoFontSize],
  ];

  for (let index = 0; index < fonts.length; index += 1) {
    const key = fonts[index][0];
    const baseline = fontSizeBaseline(fonts[index][1]);
    const value = acceptedPublicValue(document, key, Number.isInteger);

    if (value !== undefined && baseline !== undefined && value !== baseline) {
      return true;
    }
  }

  const motion = acceptedPublicValue(document, 'user.reduce_motion', isBoolean);
  const motionBase = motionBaseline(baselines.reduceMotion);

  return motion !== undefined && motionBase !== undefined && motion !== motionBase;
};

export const stateHasComposerDraft = (state) => {
  if (!state || typeof state.get !== 'function') {
    return false;
  }

  if (composerHasUnsavedReloadWork(state.get('compose'))) {
    return true;
  }

  const byId = state.getIn(['composers', 'byId']);

  return !!(byId && typeof byId.some === 'function' && byId.some(composerHasUnsavedReloadWork));
};

export const confirmPreferenceReload = ({ hasDraft, confirm, reload, message }) => {
  if (hasDraft && !confirm(message)) {
    return false;
  }

  reload();
  return true;
};
