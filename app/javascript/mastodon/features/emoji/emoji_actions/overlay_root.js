// Dedicated portal host for the shared emoji actions menu.
//
// Mobile emoji pickers live inside `.modal-root` (z-index 9999). react-overlays
// Overlay defaults to `document.body`, so the menu competes with the modal at
// the same stacking level and can paint underneath it. Desktop compose pickers
// also open while `.ui` has `pointer-events: none` via `dropdownMenuIsOpen`;
// mounting the Overlay into a body child that is not under `.ui` keeps menu
// clicks hittable without relying on an arbitrary mega z-index on the menu
// itself.

export const EMOJI_ACTIONS_OVERLAY_ROOT_ID = 'emoji-actions-overlay-root';

// The authenticated WebUI's privacy portal may be detached during a stale
// mute revision. Menu items mounted in document.body would escape that gate.
// Keep the menu root as a sibling of .ui inside the same detachable portal,
// preserving the established modal z-index and pointer-events behavior.
let privacyContainer = null;

export function setEmojiActionsOverlayPrivacyContainer(node) {
  privacyContainer = node || null;

  if (privacyContainer && typeof document !== 'undefined') {
    const root = document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID);

    if (root && root.parentNode !== privacyContainer) {
      privacyContainer.appendChild(root);
    }
  }
}

export function getEmojiActionsOverlayRoot() {
  if (typeof document === 'undefined') {
    return null;
  }

  // document.getElementById cannot see a DOM tree detached for privacy.
  let root = privacyContainer?.querySelector('#' + EMOJI_ACTIONS_OVERLAY_ROOT_ID) ||
    document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID);

  if (!root) {
    root = document.createElement('div');
    root.id = EMOJI_ACTIONS_OVERLAY_ROOT_ID;
    root.setAttribute('data-emoji-actions-overlay-root', '1');
    // Inline fallback so stacking works before stylesheet paint and in tests.
    // Stylesheet (#emoji-actions-overlay-root) remains the design-time source.
    root.style.position = 'relative';
    root.style.zIndex = '10000';
    root.style.pointerEvents = 'none';
  }

  const host = privacyContainer || document.body;
  if (root.parentNode !== host) {
    host.appendChild(root);
  }

  return root;
}

export function resetEmojiActionsOverlayRootForTests() {
  if (typeof document === 'undefined') {
    return;
  }

  const root = privacyContainer?.querySelector('#' + EMOJI_ACTIONS_OVERLAY_ROOT_ID) ||
    document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID);

  if (root && root.parentNode) {
    root.parentNode.removeChild(root);
  }
}
