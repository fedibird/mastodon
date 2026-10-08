export const COMPOSER_CREATE = 'COMPOSER_CREATE';
export const COMPOSER_DESTROY = 'COMPOSER_DESTROY';
export const COMPOSER_CONTEXT_APPLY = 'COMPOSER_CONTEXT_APPLY';
export const COMPOSER_CONTEXT_HASHTAG_TOGGLE = 'COMPOSER_CONTEXT_HASHTAG_TOGGLE';

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

export const toggleComposerManagedHashtag = (composerId, normalizedName) => targetComposerAction({
  type: COMPOSER_CONTEXT_HASHTAG_TOGGLE,
  normalizedName,
}, composerId);
