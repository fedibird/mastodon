// Long-press → open emoji actions without firing the host's short-press
// (insert / react / navigate). Shared by picker cells and reaction chips.
// After the menu opens, the same press may slide onto a menu item; release
// coordinates are reported so the menu can activate that item once.

import {
  beginEmojiActionsSlideGesture,
  createEmojiActionsSlideGestureId,
  endEmojiActionsSlideGesture,
  reportEmojiActionsSlideCancel,
  reportEmojiActionsSlideMove,
  reportEmojiActionsSlideRelease,
} from './emoji_actions/bus';

export const LONG_PRESS_MS = 480;
export const LONG_PRESS_MOVE_PX = 12;
export const LONG_PRESS_CLICK_SUPPRESS_MS = 700;

// Only the tracked touch id — never fall back to list[0] (another finger).
const pointFromTouchList = (list, id) => {
  if (!list || list.length === 0 || id === undefined || id === null) {
    return null;
  }

  const touch = Array.from(list).find(entry => entry.identifier === id);

  if (!touch) {
    return null;
  }

  return { clientX: touch.clientX, clientY: touch.clientY };
};

export function attachLongPressGesture(element, { onLongPress, onLongPressMove, onLongPressRelease } = {}) {
  if (!element || typeof onLongPress !== 'function') {
    return () => {};
  }

  let tracking = null;
  let timer = null;
  let suppressClickUntil = 0;
  let watchingDocumentTouches = false;
  let watchingDocumentPointer = false;

  const clearTimer = () => {
    if (timer !== null) {
      clearTimeout(timer);
    }
    timer = null;
  };

  // Abort an in-flight slide: end the bus session and notify the menu so any
  // slide-target highlight is cleared (multitouch / pointercancel).
  const cancelSlideGesture = () => {
    if (!tracking || !tracking.gestureId) {
      return;
    }

    const gestureId = tracking.gestureId;
    tracking.gestureId = null;
    endEmojiActionsSlideGesture(gestureId);
    reportEmojiActionsSlideCancel({ gestureId, anchor: element });
  };

  const endSlideGestureQuiet = () => {
    if (!tracking || !tracking.gestureId) {
      return;
    }

    endEmojiActionsSlideGesture(tracking.gestureId);
  };

  const onDocumentTouchStart = event => {
    // Keep watching after the menu opens (fired) so a second finger cancels slide.
    if (!tracking || tracking.kind !== 'touch' || tracking.cancelled) {
      return;
    }

    if (event.touches && event.touches.length > 1) {
      tracking.cancelled = true;
      clearTimer();
      cancelSlideGesture();
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

  const releasePointerCaptureIfNeeded = () => {
    if (!tracking || tracking.kind !== 'pointer' || !tracking.captured) {
      return;
    }

    if (typeof element.releasePointerCapture !== 'function') {
      return;
    }

    try {
      if (typeof element.hasPointerCapture !== 'function' || element.hasPointerCapture(tracking.id)) {
        element.releasePointerCapture(tracking.id);
      }
    } catch (error) {
      // Ignore release failures (already released / unsupported).
    }
  };

  // Mouse slide-to-select leaves the emoji cell; element-only listeners never
  // see that pointerup. Capture + temporary document watch cover off-cell release.
  const onDocumentPointerMove = event => {
    if (!tracking || tracking.kind !== 'pointer' || event.pointerId !== tracking.id) {
      return;
    }

    if (tracking.cancelled) {
      return;
    }

    if (tracking.fired) {
      emitSlideMove(event.clientX, event.clientY);
      return;
    }

    if (movedBeyond(event.clientX, event.clientY)) {
      tracking.cancelled = true;
      clearTimer();
      // Drop capture so a cancelled drag does not keep targeting the host;
      // still arm click suppress on pointerup (capture may already have
      // routed the forthcoming click to the original button).
      releasePointerCaptureIfNeeded();
      tracking.captured = false;
    }
  };

  const onDocumentPointerUp = event => {
    if (!tracking || tracking.kind !== 'pointer' || event.pointerId !== tracking.id) {
      return;
    }

    const fired = tracking.fired;
    const cancelled = tracking.cancelled;
    const gestureId = tracking.gestureId;
    const clientX = event.clientX;
    const clientY = event.clientY;
    clearTracking();

    if (fired) {
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
      armClickSuppress();

      if (!cancelled) {
        emitSlideReleaseAfterClear(clientX, clientY, gestureId);
      }
      return;
    }

    if (cancelled) {
      // Pre-fire drag cancel under pointer capture would otherwise synthesize
      // a click on the original emoji cell (insert / react).
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
      armClickSuppress();
    }
  };

  const onDocumentPointerCancel = event => {
    if (!tracking || tracking.kind !== 'pointer' || event.pointerId !== tracking.id) {
      return;
    }

    tracking.cancelled = true;
    clearTracking();
  };

  const disarmDocumentPointerWatch = () => {
    if (!watchingDocumentPointer) {
      return;
    }

    document.removeEventListener('pointermove', onDocumentPointerMove, true);
    document.removeEventListener('pointerup', onDocumentPointerUp, true);
    document.removeEventListener('pointercancel', onDocumentPointerCancel, true);
    watchingDocumentPointer = false;
  };

  const armDocumentPointerWatch = () => {
    if (watchingDocumentPointer) {
      return;
    }

    document.addEventListener('pointermove', onDocumentPointerMove, true);
    document.addEventListener('pointerup', onDocumentPointerUp, true);
    document.addEventListener('pointercancel', onDocumentPointerCancel, true);
    watchingDocumentPointer = true;
  };

  const clearTracking = () => {
    clearTimer();
    disarmDocumentMultiTouchWatch();
    releasePointerCaptureIfNeeded();
    disarmDocumentPointerWatch();

    if (tracking) {
      if (tracking.cancelled) {
        cancelSlideGesture();
      } else {
        // Successful release path ends the bus id without a cancel notify;
        // the menu clears highlight from handleSlideRelease instead.
        endSlideGestureQuiet();
      }
    }

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

  const armClickSuppress = () => {
    // Arm from press end, not from the 480ms fire moment. A multi-second hold
    // must still suppress the synthetic click that follows pointerup/touchend.
    suppressClickUntil = Date.now() + LONG_PRESS_CLICK_SUPPRESS_MS;
  };

  const slidePayload = (clientX, clientY) => ({
    clientX,
    clientY,
    gestureId: tracking && tracking.gestureId,
    anchor: element,
  });

  const emitSlideMove = (clientX, clientY) => {
    if (!tracking || tracking.cancelled || !tracking.gestureId) {
      return;
    }

    const payload = slidePayload(clientX, clientY);
    reportEmojiActionsSlideMove(payload);

    if (typeof onLongPressMove === 'function') {
      onLongPressMove(payload);
    }
  };

  // Capture gestureId before clearTracking; then report with those locals.
  const emitSlideReleaseAfterClear = (clientX, clientY, gestureId) => {
    if (!gestureId) {
      return;
    }

    const payload = {
      clientX,
      clientY,
      gestureId,
      anchor: element,
    };
    reportEmojiActionsSlideRelease(payload);

    if (typeof onLongPressRelease === 'function') {
      onLongPressRelease(payload);
    }
  };

  const fire = event => {
    if (!tracking || tracking.cancelled || tracking.fired) {
      return;
    }

    tracking.fired = true;
    tracking.gestureId = createEmojiActionsSlideGestureId();
    beginEmojiActionsSlideGesture({
      gestureId: tracking.gestureId,
      anchor: element,
    });

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
      gestureId: null,
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
      cancelSlideGesture();
      return;
    }

    const touch = Array.from(event.touches || []).find(entry => entry.identifier === tracking.id)
      || Array.from(event.changedTouches || []).find(entry => entry.identifier === tracking.id);

    if (!touch) {
      tracking.cancelled = true;
      clearTimer();
      cancelSlideGesture();
      return;
    }

    if (tracking.cancelled) {
      return;
    }

    // After the menu is open, allow sliding onto items (native context-menu style).
    if (tracking.fired) {
      emitSlideMove(touch.clientX, touch.clientY);
      return;
    }

    if (movedBeyond(touch.clientX, touch.clientY)) {
      tracking.cancelled = true;
      clearTimer();
    }
  };

  const onTouchEnd = event => {
    if (!tracking || tracking.kind !== 'touch') {
      return;
    }

    const fired = tracking.fired;
    const cancelled = tracking.cancelled;
    const id = tracking.id;
    const gestureId = tracking.gestureId;
    const point = pointFromTouchList(event.changedTouches, id);
    clearTracking();

    if (fired) {
      // touchend cancelability varies (Touch Events L2). Always stop
      // propagation so host React handlers cannot treat this as a short tap.
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
      armClickSuppress();

      // Multitouch / cancel must not activate; only the tracked id's point.
      if (!cancelled && point) {
        emitSlideReleaseAfterClear(point.clientX, point.clientY, gestureId);
      }
      return;
    }

    if (cancelled) {
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
      armClickSuppress();
    }
  };

  const onTouchCancel = () => {
    if (tracking) {
      tracking.cancelled = true;
    }
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
      captured: false,
      gestureId: null,
    };

    // Capture during pointerdown so off-cell move/up still reach us when the
    // browser supports it; document watch covers environments that do not.
    if (typeof element.setPointerCapture === 'function') {
      try {
        element.setPointerCapture(event.pointerId);
        tracking.captured = true;
      } catch (error) {
        tracking.captured = false;
      }
    }

    armDocumentPointerWatch();
    timer = setTimeout(() => fire(event), LONG_PRESS_MS);
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
  element.addEventListener('click', onClick, true);

  return () => {
    clearTracking();
    suppressClickUntil = 0;
    element.removeEventListener('touchstart', onTouchStart);
    element.removeEventListener('touchmove', onTouchMove);
    element.removeEventListener('touchend', onTouchEnd);
    element.removeEventListener('touchcancel', onTouchCancel);
    element.removeEventListener('pointerdown', onPointerDown);
    element.removeEventListener('click', onClick, true);
  };
}
