// Public recovery stays off. A reload after setting this key opts a browser in
// for manual checks. It is not a user-facing setting and it does not open
// IndexedDB until a recovery session is installed.
export const COMPOSER_DRAFT_RECOVERY_STORAGE_KEY = 'fedibird:composer-draft-recovery';

function browserLocalStorage () {
  try {
    if (typeof localStorage === 'undefined') {
      return null;
    }

    return localStorage;
  } catch (_error) {
    return null;
  }
}

export function composerDraftRecoveryEnabled (storage) {
  const source = storage === undefined ? browserLocalStorage() : storage;

  if (!source || typeof source.getItem !== 'function') {
    return false;
  }

  try {
    return source.getItem(COMPOSER_DRAFT_RECOVERY_STORAGE_KEY) === '1';
  } catch (_error) {
    return false;
  }
}
