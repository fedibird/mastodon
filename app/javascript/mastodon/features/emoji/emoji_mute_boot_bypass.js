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

// Frozen for this page lifetime so a click can only affect a fresh reload.
const bypassed = readBypass();

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
