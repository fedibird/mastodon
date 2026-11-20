import initialState from 'mastodon/initial_state_data';

// Escape hatch for an unreadable emoji mute document. This is not a user
// preference: it never changes server-side mute rules and is scoped to the
// current tab, account, and /web UI. A different account never inherits it.
const STORAGE_KEY = 'fedibird:emoji-mute-boot-bypass';
const viewer = initialState?.meta?.me;
const viewerKey = viewer === null || viewer === undefined ? null : String(viewer);

const sessionStore = () => {
  if (typeof window === 'undefined') {
    return null;
  }

  try {
    return window.sessionStorage;
  } catch (_error) {
    return null;
  }
};

const readBypass = () => {
  const store = sessionStore();
  if (!store || viewerKey === null || !/^\/web(?:\/|$)/.test(window.location.pathname)) {
    return false;
  }

  try {
    const requested = store.getItem(STORAGE_KEY);

    if (requested !== null && requested !== viewerKey) {
      store.removeItem(STORAGE_KEY);
      return false;
    }

    return requested === viewerKey;
  } catch (_error) {
    return false;
  }
};

// Temporary incident mitigation. Revert to false after investigating the
// startup failures. Only the /web UI bypasses the emoji mute document.
export const TEMPORARILY_DISABLE_EMOJI_MUTE_LOADING = true;
const emergencyBypass = TEMPORARILY_DISABLE_EMOJI_MUTE_LOADING &&
  typeof window !== 'undefined' && /^\/web(?:\/|$)/.test(window.location.pathname);

// Keep the bypass fixed for this page lifetime.
const bypassed = readBypass() || emergencyBypass;

export const emojiMuteBypassEnabled = () => bypassed;

export const requestEmojiMuteBypass = () => {
  const store = sessionStore();
  if (!store || viewerKey === null) {
    return false;
  }

  try {
    store.setItem(STORAGE_KEY, viewerKey);
    return true;
  } catch (_error) {
    return false;
  }
};

export const clearEmojiMuteBypass = () => {
  const store = sessionStore();
  if (!store) {
    return false;
  }

  try {
    store.removeItem(STORAGE_KEY);
    return true;
  } catch (_error) {
    return false;
  }
};
