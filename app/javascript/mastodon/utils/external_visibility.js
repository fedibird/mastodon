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

// A projection must not be copied into the composer. visibility_ex covers a
// payload that still has the masked wire visibility. fedibird_external is the
// owner-only extension and is not a compose source either.
export const isExternalProjectionStatus = status => {
  if (!status) {
    return false;
  }

  const read = name => (typeof status.get === 'function' ? status.get(name) : status[name]);

  return isExternalContentVisibility(read('visibility'))
    || isExternalContentVisibility(read('visibility_ex'))
    || !!read('fedibird_external');
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
