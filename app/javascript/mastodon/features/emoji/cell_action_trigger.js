// Event binding for per-cell manage triggers. Touch must open even when the
// browser suppresses the synthetic click after touchstart/touchend cancel.

const TAP_MOVE_PX = 12;

export function attachCellActionTriggerHandlers(trigger, { onOpen }) {
  let touchTracking = null;
  let suppressClick = false;

  const openOnce = event => {
    suppressClick = true;
    onOpen(event);
  };

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

    // Opening here keeps manage working when the UA omits the synthetic click
    // after a cancelled touch. preventDefault suppresses a duplicate click when
    // the UA would still synthesize one.
    if (event.cancelable) {
      event.preventDefault();
    }

    openOnce(event);
  };

  const onClick = event => {
    event.preventDefault();
    event.stopPropagation();

    if (suppressClick) {
      suppressClick = false;
      return;
    }

    openOnce(event);
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
