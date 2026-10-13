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
