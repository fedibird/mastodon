export const EXTERNAL_VISIBILITY = 'external';

// Composer choices. external is an internal read value and is not one of them.
export const COMPOSER_PRIVACIES = Object.freeze([
  'public',
  'unlisted',
  'private',
  'mutual',
  'limited',
  'direct',
  'personal',
]);

export const isExternalContentVisibility = value => value === EXTERNAL_VISIBILITY;

export const isExternalContentStatus = status => {
  if (!status) {
    return false;
  }

  const visibility = typeof status.get === 'function' ? status.get('visibility') : status.visibility;

  return isExternalContentVisibility(visibility);
};

// A reply, quote, edit, or redraft must not copy external into the composer.
export const composerPrivacy = (visibility, fallback) => {
  if (COMPOSER_PRIVACIES.includes(visibility)) {
    return visibility;
  }

  if (COMPOSER_PRIVACIES.includes(fallback)) {
    return fallback;
  }

  return 'public';
};
