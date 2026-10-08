import { List as ImmutableList } from 'immutable';
import { PRIMARY_COMPOSER_ID } from '../utils/composer';

export { PRIMARY_COMPOSER_ID };

const PORTABLE_COMPOSER_SEED_FIELDS = [
  'default_privacy',
  'default_sensitive',
  'default_language',
  'default_searchability',
  'default_expires_in',
  'default_expires_action',
  'poll_max_options',
  'prohibited_visibilities',
  'prohibited_words',
  'tagHistory',
];

export const selectComposer = (
  state,
  composerId = PRIMARY_COMPOSER_ID,
) => {
  if (composerId === PRIMARY_COMPOSER_ID) {
    return state.get('compose');
  }

  return state.getIn(['composers', 'byId', composerId], null);
};

export const selectPortableComposerSeed = (state) => {
  const composer = selectComposer(state, PRIMARY_COMPOSER_ID);

  if (!composer) {
    return null;
  }

  return composer.filter((_, key) => PORTABLE_COMPOSER_SEED_FIELDS.includes(key));
};

export const selectComposerManagedHashtags = (state, composerId) => {
  const composer = selectComposer(state, composerId);

  if (!composer) {
    return ImmutableList();
  }

  return composer.getIn(['context', 'managed', 'hashtags'], ImmutableList());
};

export const selectComposerEffectiveManagedHashtags = (state, composerId) => {
  const composer = selectComposer(state, composerId);

  if (!composer) {
    return ImmutableList();
  }

  const suppressed = composer.getIn(['context', 'suppressions', 'hashtags']);

  return selectComposerManagedHashtags(state, composerId).filter(tag => (
    !suppressed || !suppressed.includes(tag.get('normalizedName'))
  ));
};

export const selectPortableComposerVisible = (state, composerId) => (
  state.getIn(['settings', 'portableComposerVisibility', composerId], false) === true
);

export const PORTABLE_COMPOSER_MODE_FULL = 'full';
export const PORTABLE_COMPOSER_MODE_SIMPLE = 'simple';

export const selectPortableComposerDisplayMode = (state, composerId) => (
  state.getIn(
    ['settings', 'portableComposerDisplayMode', composerId],
    PORTABLE_COMPOSER_MODE_FULL,
  ) === PORTABLE_COMPOSER_MODE_SIMPLE
    ? PORTABLE_COMPOSER_MODE_SIMPLE
    : PORTABLE_COMPOSER_MODE_FULL
);

export const getComposerStatePath = (
  composerId = PRIMARY_COMPOSER_ID,
  ...path
) => (
  composerId === PRIMARY_COMPOSER_ID
    ? ['compose', ...path]
    : ['composers', 'byId', composerId, ...path]
);
