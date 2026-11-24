import { featureUsageFlag, initialFeaturePrefetchAllowed } from 'mastodon/feature_usage';
import { emojiPickerDisablePersonal, emojiPickerDisableStandard, emojiPickerLazyLoadStandard, emojiPickerPreferPersonal } from 'mastodon/initial_state';
import { loadStandardEmojiPicker } from './standard_emoji_loader';
import { loadPersonalEmojiStock } from './emoji_stock_source';

export function emojiPickerInitialMode(preferPersonal = emojiPickerPreferPersonal, disablePersonal = emojiPickerDisablePersonal, disableStandard = emojiPickerDisableStandard) {
  return !disablePersonal && (preferPersonal || disableStandard) ? 'personal' : 'standard';
}

// Lazy-off preload is an application decision, not a per-user service worker.
// It does not change the visible mode or move focus. An already loaded module
// stays loaded if the setting is later turned on; the next page load applies it.
export function preloadStandardEmojiPickerIfNeeded(lazyLoadStandard = emojiPickerLazyLoadStandard, disableStandard = emojiPickerDisableStandard) {
  if (disableStandard || lazyLoadStandard !== false) {
    return Promise.resolve(null);
  }

  return loadStandardEmojiPicker().catch(() => null);
}

export function preloadPersonalEmojiStockIfNeeded(lazyLoadStandard = emojiPickerLazyLoadStandard, disablePersonal = emojiPickerDisablePersonal, hasPersonalEmojiSet = featureUsageFlag('has_personal_emoji_set')) {
  // An explicit false means this document was rendered with no personal-set
  // row. An empty row still preloads, because the stock request is the safe
  // read. Opening the picker and saving a set call loadPersonalEmojiStock()
  // directly and do not pass this snapshot in.
  if (disablePersonal || lazyLoadStandard !== false || !initialFeaturePrefetchAllowed(hasPersonalEmojiSet)) {
    return Promise.resolve(null);
  }

  // Capture both synchronous API setup errors and rejected network requests.
  return Promise.resolve().then(() => loadPersonalEmojiStock()).catch(() => null);
}

// Non-lazy mode also warms the public custom emoji catalog via the caller's
// Redux store. The catalog and its search reducer stay out of this module's
// import graph; the caller provides an already-connected dispatch callback.
// A failure is recoverable from the picker, and must not reject boot.
export function preloadCustomEmojiCatalogIfNeeded(preloadCatalog, lazyLoadStandard = emojiPickerLazyLoadStandard, disableStandard = emojiPickerDisableStandard) {
  if (disableStandard || lazyLoadStandard !== false || typeof preloadCatalog !== 'function') {
    return Promise.resolve(null);
  }

  return Promise.resolve().then(preloadCatalog).catch(() => null);
}

// Non-lazy mode prepares both the standard module and the user's small,
// resolved personal stock. Neither request delays the application mount.
export function preloadEmojiPickersIfNeeded(lazyLoadStandard = emojiPickerLazyLoadStandard, disablePersonal = emojiPickerDisablePersonal, preloadCatalog = null, disableStandard = emojiPickerDisableStandard, hasPersonalEmojiSet = featureUsageFlag('has_personal_emoji_set')) {
  return Promise.all([
    preloadStandardEmojiPickerIfNeeded(lazyLoadStandard, disableStandard),
    preloadPersonalEmojiStockIfNeeded(lazyLoadStandard, disablePersonal, hasPersonalEmojiSet),
    preloadCustomEmojiCatalogIfNeeded(preloadCatalog, lazyLoadStandard, disableStandard),
  ]);
}
