// After closing a ModalRoot-backed surface (e.g. REACTION), ModalRoot may
// history.goBack() for its mastodonModalKey buffer. Pushing the detail route
// before that POP lands can be undone. Wait for POP when a modal key is
// present; otherwise navigate promptly. Always settle at most once.

export const MODAL_HISTORY_SETTLE_FALLBACK_MS = 100;

/**
 * @param {object} history React Router / history instance
 * @param {string} path Detail path to push
 * @param {{ fallbackMs?: number, now?: () => number }} [options]
 * @returns {() => void} cancel pending navigation
 */
export function navigateAfterPickerClose(history, path, options = {}) {
  if (!history || !path || typeof history.push !== 'function') {
    return () => {};
  }

  const fallbackMs = typeof options.fallbackMs === 'number'
    ? options.fallbackMs
    : MODAL_HISTORY_SETTLE_FALLBACK_MS;

  let settled = false;
  let unlisten = null;
  let fallbackTimer = null;

  const cleanup = () => {
    if (unlisten) {
      unlisten();
      unlisten = null;
    }

    if (fallbackTimer !== null) {
      clearTimeout(fallbackTimer);
      fallbackTimer = null;
    }
  };

  const pushOnce = () => {
    if (settled) {
      return;
    }

    settled = true;
    cleanup();
    history.push(path);
  };

  const modalKey = history.location
    && history.location.state
    && history.location.state.mastodonModalKey;

  if (!modalKey) {
    // No modal history buffer — push on the next task so Redux/dropdown close
    // can flush first without racing a POP.
    fallbackTimer = setTimeout(pushOnce, 0);
    return cleanup;
  }

  if (typeof history.listen === 'function') {
    unlisten = history.listen((_location, action) => {
      if (action === 'POP') {
        pushOnce();
      }
    });
  }

  // ModalRoot may skip goBack if the key no longer matches; do not hang.
  fallbackTimer = setTimeout(pushOnce, fallbackMs);

  return cleanup;
}
