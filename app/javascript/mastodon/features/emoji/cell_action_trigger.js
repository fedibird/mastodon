// Event binding for per-cell manage triggers. Touch must open even when the
// browser suppresses the synthetic click after touchstart/touchend cancel.

const TAP_MOVE_PX = 12;
const SYNTHETIC_CLICK_WINDOW_MS = 700;

export function attachCellActionTriggerHandlers(trigger, { onOpen }) {
  let touchTracking = null;
  let suppressClickUntil = 0;

  const clearTouch = () => {
    touchTracking = null;
  };

  const onTouchStart = event => {
    event.stopPropagation();

    if (!event.touches || event.touches.length !== 1) {
      clearTouch();
      return;
    }

    const touch = event.touches[0];
    touchTracking = {
      id: touch.identifier,
      x: touch.clientX,
      y: touch.clientY,
      cancelled: false,
    };
  };

  const onTouchMove = event => {
    if (!touchTracking) {
      return;
    }

    const touch = Array.from(event.touches || []).find(entry => entry.identifier === touchTracking.id)
      || Array.from(event.changedTouches || []).find(entry => entry.identifier === touchTracking.id);

    if (!touch) {
      return;
    }

    const dx = touch.clientX - touchTracking.x;
    const dy = touch.clientY - touchTracking.y;

    if ((dx * dx) + (dy * dy) > TAP_MOVE_PX * TAP_MOVE_PX) {
      touchTracking.cancelled = true;
    }
  };

  const onTouchCancel = event => {
    event.stopPropagation();
    clearTouch();
  };

  const onTouchEnd = event => {
    event.stopPropagation();

    const tracking = touchTracking;
    clearTouch();

    if (!tracking || tracking.cancelled) {
      return;
    }

    const touch = Array.from(event.changedTouches || []).find(entry => entry.identifier === tracking.id);

    if (!touch) {
      return;
    }

    // Open on touchend so manage works when the UA omits the synthetic click.
    // Only that following click (if any) is suppressed — never ordinary mouse clicks.
    if (event.cancelable) {
      event.preventDefault();
    }

    suppressClickUntil = Date.now() + SYNTHETIC_CLICK_WINDOW_MS;
    onOpen(event);
  };

  const onClick = event => {
    event.preventDefault();
    event.stopPropagation();

    if (Date.now() < suppressClickUntil) {
      suppressClickUntil = 0;
      return;
    }

    // Plain mouse / keyboard activation — do not arm suppressClick.
    onOpen(event);
  };

  const stopBubble = event => {
    event.stopPropagation();
  };

  trigger.addEventListener('touchstart', onTouchStart, { passive: true });
  trigger.addEventListener('touchmove', onTouchMove, { passive: true });
  trigger.addEventListener('touchend', onTouchEnd, { passive: false });
  trigger.addEventListener('touchcancel', onTouchCancel, { passive: true });
  trigger.addEventListener('click', onClick);
  trigger.addEventListener('mousedown', stopBubble);
  trigger.addEventListener('mouseup', stopBubble);
  trigger.addEventListener('pointerdown', stopBubble);
  trigger.addEventListener('pointerup', stopBubble);

  return () => {
    trigger.removeEventListener('touchstart', onTouchStart);
    trigger.removeEventListener('touchmove', onTouchMove);
    trigger.removeEventListener('touchend', onTouchEnd);
    trigger.removeEventListener('touchcancel', onTouchCancel);
    trigger.removeEventListener('click', onClick);
    trigger.removeEventListener('mousedown', stopBubble);
    trigger.removeEventListener('mouseup', stopBubble);
    trigger.removeEventListener('pointerdown', stopBubble);
    trigger.removeEventListener('pointerup', stopBubble);
  };
}
