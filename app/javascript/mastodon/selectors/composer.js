export const PRIMARY_COMPOSER_ID = 'primary';

export const selectComposer = (
  state,
  composerId = PRIMARY_COMPOSER_ID,
) => {
  if (composerId === PRIMARY_COMPOSER_ID) {
    return state.get('compose');
  }

  return null;
};
