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

export function getEmojiActionsOverlayRoot() {
  if (typeof document === 'undefined') {
    return null;
  }

  let root = document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID);

  if (!root) {
    root = document.createElement('div');
    root.id = EMOJI_ACTIONS_OVERLAY_ROOT_ID;
    root.setAttribute('data-emoji-actions-overlay-root', '1');
    // Inline fallback so stacking works before stylesheet paint and in tests.
    // Stylesheet (#emoji-actions-overlay-root) remains the design-time source.
    root.style.position = 'relative';
    root.style.zIndex = '10000';
    root.style.pointerEvents = 'none';
    document.body.appendChild(root);
  }

  return root;
}

export function resetEmojiActionsOverlayRootForTests() {
  if (typeof document === 'undefined') {
    return;
  }

  const root = document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID);

  if (root && root.parentNode) {
    root.parentNode.removeChild(root);
  }
}
