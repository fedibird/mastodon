const VISIBILITY_ORDER = ['public', 'unlisted', 'private', 'mutual', 'limited', 'direct', 'personal'];
const SEARCHABILITY_FOR_VISIBILITY = ['public', 'private', 'private', 'direct', 'direct', 'direct', 'direct'];

export const searchabilityCap = (visibility, searchability) => {
  const visibilityIndex = VISIBILITY_ORDER.indexOf(visibility);
  const searchabilityIndex = VISIBILITY_ORDER.indexOf(searchability);

  return SEARCHABILITY_FOR_VISIBILITY[Math.max(visibilityIndex, searchabilityIndex, 0)];
};

export const effectiveSearchability = (privacy, defaultSearchability) => (
  searchabilityCap(privacy, defaultSearchability)
);

// Keep the desired value separate from the cap so narrowing privacy is reversible.
// A saved/redrafted post also has a desired value, independent of account defaults.
export const composerSearchability = (composer, privacy = composer.get('privacy')) => (
  effectiveSearchability(privacy, composer.get('searchability_desired') || (
    composer.get('searchability_manual') ? composer.get('searchability') : composer.get('default_searchability')
  ))
);

export const searchabilityIsChanged = ({ searchability, privacy, defaultSearchability }) => (
  Boolean(searchability) && searchabilityCap(privacy, searchability) !== effectiveSearchability(privacy, defaultSearchability)
);
