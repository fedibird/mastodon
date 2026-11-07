import { emojiPickerLazyLoadStandard, emojiPickerPreferPersonal } from 'mastodon/initial_state';
import { loadStandardEmojiPicker } from './standard_emoji_loader';

export function emojiPickerInitialMode(preferPersonal = emojiPickerPreferPersonal) {
  return preferPersonal ? 'personal' : 'standard';
}

// Lazy-off preload is an application decision, not a per-user service worker.
// It does not change the visible mode or move focus. An already loaded module
// stays loaded if the setting is later turned on; the next page load applies it.
export function preloadStandardEmojiPickerIfNeeded(lazyLoadStandard = emojiPickerLazyLoadStandard) {
  if (lazyLoadStandard !== false) {
    return Promise.resolve(null);
  }

  return loadStandardEmojiPicker().catch(() => null);
}
