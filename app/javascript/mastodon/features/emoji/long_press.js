// Long-press → open emoji actions without firing the host's short-press
// (insert / react / navigate). Shared by picker cells and reaction chips.

export const LONG_PRESS_MS = 480;
export const LONG_PRESS_MOVE_PX = 12;
export const LONG_PRESS_CLICK_SUPPRESS_MS = 700;

export function attachLongPressGesture(element, { onLongPress }) {
  if (!element || typeof onLongPress !== 'function') {
    return () => {};
  }

  let tracking = null;
  let timer = null;
  let suppressClickUntil = 0;
  let watchingDocumentTouches = false;

  const clearTimer = () => {
    if (timer !== null) {
      clearTimeout(timer);
    }
    timer = null;
  };

  const onDocumentTouchStart = event => {
    if (!tracking || tracking.kind !== 'touch' || tracking.fired || tracking.cancelled) {
      return;
    }

    // A second finger on any element (not only this cell) must cancel.
    if (event.touches && event.touches.length > 1) {
      tracking.cancelled = true;
      clearTimer();
    }
  };

  const disarmDocumentMultiTouchWatch = () => {
    if (!watchingDocumentTouches) {
      return;
    }

    document.removeEventListener('touchstart', onDocumentTouchStart, true);
    watchingDocumentTouches = false;
  };

  const armDocumentMultiTouchWatch = () => {
    if (watchingDocumentTouches) {
      return;
    }

    document.addEventListener('touchstart', onDocumentTouchStart, { capture: true, passive: true });
    watchingDocumentTouches = true;
  };

  const clearTracking = () => {
    clearTimer();
    disarmDocumentMultiTouchWatch();
    tracking = null;
  };

  const movedBeyond = (x, y) => {
    if (!tracking) {
      return true;
    }

    const dx = x - tracking.x;
    const dy = y - tracking.y;
    return (dx * dx) + (dy * dy) > LONG_PRESS_MOVE_PX * LONG_PRESS_MOVE_PX;
  };

  const fire = event => {
    if (!tracking || tracking.cancelled || tracking.fired) {
      return;
    }

    tracking.fired = true;
    suppressClickUntil = Date.now() + LONG_PRESS_CLICK_SUPPRESS_MS;

    if (event && event.cancelable) {
      event.preventDefault();
    }

    if (event && typeof event.stopPropagation === 'function') {
      event.stopPropagation();
    }

    onLongPress(event);
  };

  const onTouchStart = event => {
    // A new intentional gesture supersedes leftover synthetic-click suppress.
    suppressClickUntil = 0;

    if (!event.touches || event.touches.length !== 1) {
      clearTracking();
      return;
    }

    const touch = event.touches[0];
    clearTracking();
    tracking = {
      id: touch.identifier,
      x: touch.clientX,
      y: touch.clientY,
      cancelled: false,
      fired: false,
      kind: 'touch',
    };
    armDocumentMultiTouchWatch();
    timer = setTimeout(() => fire(event), LONG_PRESS_MS);
  };

  const onTouchMove = event => {
    if (!tracking || tracking.kind !== 'touch') {
      return;
    }

    if (event.touches && event.touches.length > 1) {
      tracking.cancelled = true;
      clearTimer();
      return;
    }

    const touch = Array.from(event.touches || []).find(entry => entry.identifier === tracking.id)
      || Array.from(event.changedTouches || []).find(entry => entry.identifier === tracking.id);

    if (!touch || movedBeyond(touch.clientX, touch.clientY)) {
      tracking.cancelled = true;
      clearTimer();
    }
  };

  const onTouchEnd = event => {
    if (!tracking || tracking.kind !== 'touch') {
      return;
    }

    const fired = tracking.fired;
    clearTracking();

    if (fired && event.cancelable) {
      event.preventDefault();
      event.stopPropagation();
    }
  };

  const onTouchCancel = () => {
    clearTracking();
  };

  const onPointerDown = event => {
    // Touch is handled via Touch Events so we do not double-arm.
    if (event.pointerType === 'touch') {
      return;
    }

    // A new intentional gesture supersedes leftover synthetic-click suppress.
    suppressClickUntil = 0;

    // Some synthetic events omit button; treat that as the primary button.
    if (typeof event.button === 'number' && event.button !== 0) {
      return;
    }

    clearTracking();
    tracking = {
      id: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      cancelled: false,
      fired: false,
      kind: 'pointer',
    };
    timer = setTimeout(() => fire(event), LONG_PRESS_MS);
  };

  const onPointerMove = event => {
    if (!tracking || tracking.kind !== 'pointer' || event.pointerId !== tracking.id) {
      return;
    }

    if (movedBeyond(event.clientX, event.clientY)) {
      tracking.cancelled = true;
      clearTimer();
    }
  };

  const onPointerUp = event => {
    if (!tracking || tracking.kind !== 'pointer' || event.pointerId !== tracking.id) {
      return;
    }

    const fired = tracking.fired;
    clearTracking();

    if (fired && event.cancelable) {
      event.preventDefault();
      event.stopPropagation();
    }
  };

  const onPointerCancel = event => {
    if (!tracking || tracking.kind !== 'pointer' || event.pointerId !== tracking.id) {
      return;
    }

    clearTracking();
  };

  const onClick = event => {
    if (Date.now() >= suppressClickUntil) {
      return;
    }

    // Accessibility activation (Enter/Space) uses detail === 0. Never suppress it.
    if (event.detail === 0) {
      return;
    }

    // Consume only the first pointer/synthetic click after a long-press.
    suppressClickUntil = 0;
    event.preventDefault();
    event.stopPropagation();
  };

  element.addEventListener('touchstart', onTouchStart, { passive: true });
  element.addEventListener('touchmove', onTouchMove, { passive: true });
  element.addEventListener('touchend', onTouchEnd, { passive: false });
  element.addEventListener('touchcancel', onTouchCancel, { passive: true });
  element.addEventListener('pointerdown', onPointerDown);
  element.addEventListener('pointermove', onPointerMove);
  element.addEventListener('pointerup', onPointerUp);
  element.addEventListener('pointercancel', onPointerCancel);
  element.addEventListener('click', onClick, true);

  return () => {
    clearTracking();
    suppressClickUntil = 0;
    element.removeEventListener('touchstart', onTouchStart);
    element.removeEventListener('touchmove', onTouchMove);
    element.removeEventListener('touchend', onTouchEnd);
    element.removeEventListener('touchcancel', onTouchCancel);
    element.removeEventListener('pointerdown', onPointerDown);
    element.removeEventListener('pointermove', onPointerMove);
    element.removeEventListener('pointerup', onPointerUp);
    element.removeEventListener('pointercancel', onPointerCancel);
    element.removeEventListener('click', onClick, true);
  };
}
