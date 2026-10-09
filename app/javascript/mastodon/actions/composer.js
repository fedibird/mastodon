export const COMPOSER_CREATE = 'COMPOSER_CREATE';
export const COMPOSER_DESTROY = 'COMPOSER_DESTROY';
export const COMPOSER_CONTEXT_APPLY = 'COMPOSER_CONTEXT_APPLY';
export const COMPOSER_CONTEXT_HASHTAG_TOGGLE = 'COMPOSER_CONTEXT_HASHTAG_TOGGLE';
export const COMPOSER_SURFACE_ACCEPT = 'COMPOSER_SURFACE_ACCEPT';
export const COMPOSER_SENDER_IDENTITY_SELECT = 'COMPOSER_SENDER_IDENTITY_SELECT';

let surfaceEpochSerial = 0;

export const targetComposerAction = (action, composerId) => ({
  ...action,
  meta: {
    ...action.meta,
    composerId,
  },
});

export const createComposer = (composerId, seed) => targetComposerAction(
  (seed === undefined || seed === null) ? { type: COMPOSER_CREATE } : { type: COMPOSER_CREATE, seed },
  composerId,
);

export const destroyComposer = composerId => targetComposerAction(
  { type: COMPOSER_DESTROY },
  composerId,
);

export const applyComposerPostingContext = (composerId, postingContext, postingContextAccountId) => targetComposerAction({
  type: COMPOSER_CONTEXT_APPLY,
  postingContext: postingContext === undefined ? null : postingContext,
  postingContextAccountId: (
    postingContextAccountId === undefined || postingContextAccountId === null || postingContextAccountId === ''
      ? null
      : String(postingContextAccountId)
  ),
}, composerId);

export const applyComposerSurface = (composerId, surface, postingContext, postingContextAccountId) => {
  surfaceEpochSerial += 1;

  return targetComposerAction({
    type: COMPOSER_CONTEXT_APPLY,
    surface,
    hasPostingContext: postingContext !== undefined,
    postingContext: postingContext === undefined ? null : postingContext,
    postingContextAccountId: (
      postingContextAccountId === undefined || postingContextAccountId === null || postingContextAccountId === ''
        ? null
        : String(postingContextAccountId)
    ),
    surfaceEpoch: surfaceEpochSerial,
  }, composerId);
};

export const acceptComposerSurface = composerId => targetComposerAction({
  type: COMPOSER_SURFACE_ACCEPT,
}, composerId);

export const toggleComposerManagedHashtag = (composerId, normalizedName) => targetComposerAction({
  type: COMPOSER_CONTEXT_HASHTAG_TOGGLE,
  normalizedName,
}, composerId);
