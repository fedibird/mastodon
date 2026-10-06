import { PRIMARY_COMPOSER_ID } from '../utils/composer';

export { PRIMARY_COMPOSER_ID };

export const selectComposer = (
  state,
  composerId = PRIMARY_COMPOSER_ID,
) => {
  if (composerId === PRIMARY_COMPOSER_ID) {
    return state.get('compose');
  }

  return null;
};
