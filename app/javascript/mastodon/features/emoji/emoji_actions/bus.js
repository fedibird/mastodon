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

function normalizeReactionContext(reaction) {
  if (!reaction || typeof reaction !== 'object') {
    return null;
  }

  const name = reaction.name;

  if (typeof name !== 'string' || name === '') {
    return null;
  }

  return {
    name,
    domain: reaction.domain || null,
    url: reaction.url || null,
    static_url: reaction.static_url || reaction.staticUrl || null,
    my_reaction: Boolean(reaction.my_reaction || reaction.myReaction),
    reaction_limit_reached: Boolean(
      reaction.reaction_limit_reached || reaction.reactionLimitReached,
    ),
    disabled: Boolean(reaction.disabled),
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
 * @param {object} [context.reaction] Reaction chip payload when source is reaction.
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
    reaction: normalizeReactionContext(context.reaction),
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

export { normalizeReactionContext };
