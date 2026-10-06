export const COMPOSER_CREATE = 'COMPOSER_CREATE';
export const COMPOSER_DESTROY = 'COMPOSER_DESTROY';

export const targetComposerAction = (action, composerId) => ({
  ...action,
  meta: {
    ...action.meta,
    composerId,
  },
});

export const createComposer = composerId => targetComposerAction(
  { type: COMPOSER_CREATE },
  composerId,
);

export const destroyComposer = composerId => targetComposerAction(
  { type: COMPOSER_DESTROY },
  composerId,
);
