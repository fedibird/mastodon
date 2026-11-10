// After closing a ModalRoot-backed surface (e.g. REACTION), ModalRoot may
// history.goBack() for its mastodonModalKey buffer. Pushing the detail route
// before that POP lands can be undone. When a modal key is present, wait for
// the real POP if goBack ran; if goBack was skipped, push after the close
// flush. Never treat a fixed timeout as "POP completed".

/**
 * @param {object} history React Router / history instance
 * @param {string} path Detail path to push
 * @param {{ afterCloseFlush?: (cb: () => void) => () => void }} [options]
 *   afterCloseFlush(cb) schedules cb after ModalRoot's close commit opportunity
 *   and may return a cancel function.
 * @returns {() => void} cancel pending navigation
 */
export function navigateAfterPickerClose(history, path, options = {}) {
  if (!history || !path || typeof history.push !== 'function') {
    return () => {};
  }

  let settled = false;
  let unlisten = null;
  let cancelFlush = null;
  let originalGoBack = null;

  const restoreGoBack = () => {
    if (originalGoBack && history.goBack !== originalGoBack) {
      history.goBack = originalGoBack;
    }
    originalGoBack = null;
  };

  const cleanup = () => {
    if (unlisten) {
      unlisten();
      unlisten = null;
    }

    if (typeof cancelFlush === 'function') {
      cancelFlush();
      cancelFlush = null;
    }

    restoreGoBack();
  };

  const pushOnce = () => {
    if (settled) {
      return;
    }

    settled = true;
    cleanup();
    history.push(path);
  };

  const scheduleFlush = (cb) => {
    if (typeof options.afterCloseFlush === 'function') {
      const cancel = options.afterCloseFlush(cb);
      return typeof cancel === 'function' ? cancel : null;
    }

    const id = setTimeout(cb, 0);
    return () => clearTimeout(id);
  };

  const modalKey = history.location
    && history.location.state
    && history.location.state.mastodonModalKey;

  if (!modalKey) {
    // No modal history buffer — push on the next task so Redux/dropdown close
    // can flush first without racing a POP.
    cancelFlush = scheduleFlush(pushOnce);
    return cleanup;
  }

  let goBackSeen = false;

  if (typeof history.goBack === 'function') {
    originalGoBack = history.goBack.bind(history);
    history.goBack = (...args) => {
      goBackSeen = true;
      const fn = originalGoBack;
      restoreGoBack();
      return fn(...args);
    };
  }

  if (typeof history.listen === 'function') {
    unlisten = history.listen((_location, action) => {
      if (action === 'POP') {
        pushOnce();
      }
    });
  }

  // After ModalRoot's close commit: if goBack ran, keep waiting for POP only.
  // If goBack was skipped (key mismatch / no buffer), push without hanging.
  cancelFlush = scheduleFlush(() => {
    cancelFlush = null;

    if (settled) {
      return;
    }

    if (goBackSeen) {
      return;
    }

    restoreGoBack();
    pushOnce();
  });

  return cleanup;
}
