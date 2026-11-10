import { emojiPickerDisablePersonal, emojiPickerLazyLoadStandard, emojiPickerPreferPersonal } from 'mastodon/initial_state';
import { loadStandardEmojiPicker } from './standard_emoji_loader';
import { loadPersonalEmojiStock } from './emoji_stock_source';

export function emojiPickerInitialMode(preferPersonal = emojiPickerPreferPersonal, disablePersonal = emojiPickerDisablePersonal) {
  return !disablePersonal && preferPersonal ? 'personal' : 'standard';
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

export function preloadPersonalEmojiStockIfNeeded(lazyLoadStandard = emojiPickerLazyLoadStandard, disablePersonal = emojiPickerDisablePersonal) {
  if (disablePersonal || lazyLoadStandard !== false) {
    return Promise.resolve(null);
  }

  // Capture both synchronous API setup errors and rejected network requests.
  return Promise.resolve().then(() => loadPersonalEmojiStock()).catch(() => null);
}

// Non-lazy mode prepares both the standard module and the user's small,
// resolved personal stock. Neither request delays the application mount.
export function preloadEmojiPickersIfNeeded(lazyLoadStandard = emojiPickerLazyLoadStandard, disablePersonal = emojiPickerDisablePersonal) {
  return Promise.all([
    preloadStandardEmojiPickerIfNeeded(lazyLoadStandard),
    preloadPersonalEmojiStockIfNeeded(lazyLoadStandard, disablePersonal),
  ]);
}
