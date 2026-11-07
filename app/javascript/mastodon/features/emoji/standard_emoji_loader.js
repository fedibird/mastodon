import * as asyncComponents from 'mastodon/features/ui/util/async-components';

// Page-wide cache for the standard picker module. Each picker keeps its own
// mode, search, and focus; this cache only shares the loaded module.
// A rejected import is forgotten so the next request can try again.
let cachedModule = null;
let pending = null;

function toPickerModule(loaded) {
  if (!loaded || typeof loaded.Picker !== 'function' || typeof loaded.Emoji !== 'function') {
    throw new Error('Standard emoji picker module is missing Picker or Emoji');
  }

  return {
    Picker: loaded.Picker,
    Emoji: loaded.Emoji,
  };
}

export function loadStandardEmojiPicker() {
  if (cachedModule) {
    return Promise.resolve(cachedModule);
  }

  if (!pending) {
    // Start the import immediately so concurrent callers share this promise
    // instead of each waiting for a later tick to create their own.
    let imported;

    try {
      imported = asyncComponents.EmojiPicker();
    } catch (error) {
      return Promise.reject(error);
    }

    pending = Promise.resolve(imported).then(loaded => {
      cachedModule = toPickerModule(loaded);
      pending = null;
      return cachedModule;
    }).catch(error => {
      pending = null;
      throw error;
    });
  }

  return pending;
}

export function resetStandardEmojiPickerLoaderForTests() {
  cachedModule = null;
  pending = null;
}
