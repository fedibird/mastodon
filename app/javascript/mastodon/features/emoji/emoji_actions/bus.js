import { normalizeReference } from './reference';

// Single in-memory channel for openEmojiActions. The menu controller
// registers once; hosts never attach their own document-wide listeners.

const EVENT = 'mastodon:open-emoji-actions';

let listener = null;

export function setEmojiActionsListener(next) {
  listener = typeof next === 'function' ? next : null;

  return () => {
    if (listener === next) {
      listener = null;
    }
  };
}

/**
 * Open the shared emoji actions menu for a typed reference.
 *
 * @param {object} reference Typed emoji reference (unicode / local / remote).
 * @param {object} [context]
 * @param {Element} [context.anchor] Element the menu anchors to.
 * @param {string|number} [context.status_id]
 * @param {string|number} [context.account_id]
 * @param {string} [context.source] Host label for tests / diagnostics.
 */
export function openEmojiActions(reference, context = {}) {
  const normalized = normalizeReference(reference);

  if (!normalized) {
    return false;
  }

  const detail = {
    reference: normalized,
    anchor: context.anchor || null,
    status_id: context.status_id || null,
    account_id: context.account_id || null,
    source: context.source || null,
  };

  if (listener) {
    listener(detail);
    return true;
  }

  if (typeof document !== 'undefined' && typeof document.dispatchEvent === 'function') {
    document.dispatchEvent(new CustomEvent(EVENT, { detail }));
  }

  return false;
}

export function emojiActionsEventName() {
  return EVENT;
}

export function resetEmojiActionsBusForTests() {
  listener = null;
}
