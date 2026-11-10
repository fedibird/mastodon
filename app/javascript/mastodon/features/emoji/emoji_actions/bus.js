import { normalizeReference } from './reference';

// Single in-memory channel for openEmojiActions. The menu controller
// registers once; hosts never attach their own document-wide listeners.

const EVENT = 'mastodon:open-emoji-actions';

let listener = null;
let slideMoveListener = null;
let slideReleaseListener = null;
let activeSlideGesture = null;
let gestureSeq = 0;

export function createEmojiActionsSlideGestureId() {
  gestureSeq += 1;
  return `emoji-slide-${gestureSeq}-${Date.now()}`;
}

export function beginEmojiActionsSlideGesture({ gestureId, anchor } = {}) {
  if (!gestureId) {
    activeSlideGesture = null;
    return null;
  }

  activeSlideGesture = {
    gestureId,
    anchor: anchor || null,
  };

  return activeSlideGesture;
}

export function peekEmojiActionsSlideGesture(anchor = undefined) {
  if (!activeSlideGesture) {
    return null;
  }

  if (anchor !== undefined && activeSlideGesture.anchor !== anchor) {
    return null;
  }

  return activeSlideGesture;
}

export function endEmojiActionsSlideGesture(gestureId) {
  if (!activeSlideGesture) {
    return;
  }

  if (gestureId && activeSlideGesture.gestureId !== gestureId) {
    return;
  }

  activeSlideGesture = null;
}

export function setEmojiActionsListener(next) {
  listener = typeof next === 'function' ? next : null;

  return () => {
    if (listener === next) {
      listener = null;
    }
  };
}

// Long-press slide-to-select: after the menu opens, move/release coordinates
// from the still-held press are reported here (not via permanent document
// gesture listeners on unrelated media).
export function setEmojiActionsSlideListeners({ onMove, onRelease } = {}) {
  slideMoveListener = typeof onMove === 'function' ? onMove : null;
  slideReleaseListener = typeof onRelease === 'function' ? onRelease : null;

  return () => {
    if (slideMoveListener === onMove) {
      slideMoveListener = null;
    }

    if (slideReleaseListener === onRelease) {
      slideReleaseListener = null;
    }
  };
}

export function reportEmojiActionsSlideMove(payload) {
  if (slideMoveListener && payload) {
    slideMoveListener(payload);
  }
}

export function reportEmojiActionsSlideRelease(payload) {
  if (slideReleaseListener && payload) {
    return slideReleaseListener(payload);
  }

  return false;
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
 * @param {string} [context.slideGestureId] Optional long-press slide gesture id.
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
    slideGestureId: context.slideGestureId || null,
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
  slideMoveListener = null;
  slideReleaseListener = null;
  activeSlideGesture = null;
  gestureSeq = 0;
}

export { normalizeReactionContext };
