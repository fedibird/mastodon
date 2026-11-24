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

// The emergency WebUI bypass is off. Fail-soft startup keeps the interface
// usable and hides unverified emoji instead of skipping the mute document.
export const TEMPORARILY_DISABLE_EMOJI_MUTE_LOADING = false;
const emergencyBypass = TEMPORARILY_DISABLE_EMOJI_MUTE_LOADING &&
  typeof window !== 'undefined' && /^\/web(?:\/|$)/.test(window.location.pathname);

// A stored opt-in from the incident bypass is not applied. Fail-soft ignore
// is an in-memory choice for this page view and does not survive reload.
const bypassed = emergencyBypass;

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
