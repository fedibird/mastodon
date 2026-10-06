export const targetComposerAction = (action, composerId) => ({
  ...action,
  meta: {
    ...action.meta,
    composerId,
  },
});
