import React from 'react';

// A short movement wins over the long-press timer, so an ordinary swipe keeps
// the timeline's native scrolling/momentum. Only a stationary 400ms hold
// redirects the *existing* gesture into the clipped card body.
const HOLD_DELAY_MS = 400;
const MOVE_SLOP_PX = 8;
const INTERACTIVE = 'a, button, input, textarea, select, label, summary, [role="button"], [contenteditable]';

export function canStartCardBodyHold (target) {
  return !(target && target.closest && target.closest(INTERACTIVE));
}

export default function useCardBodyHoldScroll (viewportRef, enabled, setHoldActive) {
  React.useEffect(() => {
    const viewport = viewportRef.current;
    if (!enabled || !viewport) {
      setHoldActive(false);
      return undefined;
    }

    let press = null;
    let holdTimer = null;
    let suppressClick = false;
    let listeningForMouse = false;
    let listeningForInterruption = false;

    // Subscribe only during an ongoing press; cards must not accumulate
    // global listeners while idle in a long timeline.
    const stopInterruptionTracking = () => {
      if (listeningForInterruption) {
        window.removeEventListener('blur', onWindowBlur);
        document.removeEventListener('visibilitychange', onVisibilityChange);
        listeningForInterruption = false;
      }
    };

    const stopMouseTracking = () => {
      if (listeningForMouse) {
        document.removeEventListener('mousemove', onMouseMove);
        document.removeEventListener('mouseup', onMouseUp, true);
        listeningForMouse = false;
      }
    };

    const stopTimer = () => {
      if (holdTimer !== null) {
        window.clearTimeout(holdTimer);
        holdTimer = null;
      }
    };

    const release = () => {
      stopTimer();
      stopInterruptionTracking();
      const wasActive = Boolean(press && press.active);
      if (press && press.type === 'mouse') {
        stopMouseTracking();
      }
      press = null;
      if (wasActive) {
        setHoldActive(false);
      }
      return wasActive;
    };

    const start = (type, identifier, x, y, target) => {
      release();
      suppressClick = false;
      if (!canStartCardBodyHold(target)) {
        return;
      }

      press = { type, identifier, x, y, lastY: y, active: false };
      window.addEventListener('blur', onWindowBlur);
      document.addEventListener('visibilitychange', onVisibilityChange);
      listeningForInterruption = true;
      holdTimer = window.setTimeout(() => {
        holdTimer = null;
        if (press && press.type === type && press.identifier === identifier) {
          press.active = true;
          setHoldActive(true);
        }
      }, HOLD_DELAY_MS);
    };

    const move = (type, identifier, x, y, event) => {
      if (!press || press.type !== type || press.identifier !== identifier) {
        return;
      }

      if (!press.active) {
        if (Math.hypot(x - press.x, y - press.y) > MOVE_SLOP_PX) {
          release();
        }
        return;
      }

      // Once native panning owns a touch gesture, do not move both the
      // timeline and the inner body. Yield to the browser instead.
      if (type === 'touch' && !event.cancelable) {
        release();
        return;
      }
      event.preventDefault();

      const dy = y - press.lastY;
      viewport.scrollTop -= dy;
      press.lastY = y;
    };

    const onTouchStart = event => {
      if (!event.touches || event.touches.length !== 1) {
        release();
        return;
      }

      const touch = event.touches[0];
      start('touch', touch.identifier, touch.clientX, touch.clientY, event.target);
    };

    const onTouchMove = event => {
      if (!press || press.type !== 'touch') {
        return;
      }

      if (!event.touches || event.touches.length !== 1) {
        release();
        return;
      }

      const touch = event.touches[0];
      move('touch', touch.identifier, touch.clientX, touch.clientY, event);
    };

    const onTouchEnd = () => {
      if (press && press.type === 'touch') {
        suppressClick = release() || suppressClick;
      }
    };

    const onTouchCancel = () => {
      release();
    };

    const onMouseDown = event => {
      if (event.button === 0) {
        start('mouse', 'primary', event.clientX, event.clientY, event.target);
        if (press && press.type === 'mouse') {
          // Avoid O(number of visible cards) document listeners on every
          // mousemove. Only the card with a pending/active press needs them.
          document.addEventListener('mousemove', onMouseMove);
          document.addEventListener('mouseup', onMouseUp, true);
          listeningForMouse = true;
        }
      }
    };

    const onMouseMove = event => {
      if (!press || press.type !== 'mouse') {
        return;
      }

      if (!(event.buttons & 1)) {
        release();
        return;
      }

      move('mouse', 'primary', event.clientX, event.clientY, event);
    };

    // Capture mouseup before StatusContent.handleMouseUp can open the status.
    // It reacts to small mouse movements even when there is no click handler.
    const onMouseUp = event => {
      if (press && press.type === 'mouse') {
        const wasActive = release();
        if (wasActive) {
          suppressClick = true;
          event.preventDefault();
          event.stopPropagation();
        }
      }
    };

    const onClickCapture = event => {
      if (suppressClick) {
        suppressClick = false;
        event.preventDefault();
        event.stopPropagation();
      }
    };

    const onContextMenu = event => {
      if (press && press.active) {
        event.preventDefault();
        event.stopPropagation();
      }
    };

    function onWindowBlur () {
      release();
    }

    function onVisibilityChange () {
      if (document.hidden) {
        release();
      }
    }

    viewport.addEventListener('touchstart', onTouchStart, { passive: true });
    viewport.addEventListener('touchmove', onTouchMove, { passive: false });
    viewport.addEventListener('touchend', onTouchEnd);
    viewport.addEventListener('touchcancel', onTouchCancel);
    viewport.addEventListener('mousedown', onMouseDown);
    viewport.addEventListener('click', onClickCapture, true);
    viewport.addEventListener('contextmenu', onContextMenu);
    return () => {
      release();
      viewport.removeEventListener('touchstart', onTouchStart);
      viewport.removeEventListener('touchmove', onTouchMove);
      viewport.removeEventListener('touchend', onTouchEnd);
      viewport.removeEventListener('touchcancel', onTouchCancel);
      viewport.removeEventListener('mousedown', onMouseDown);
      viewport.removeEventListener('click', onClickCapture, true);
      viewport.removeEventListener('contextmenu', onContextMenu);
      stopMouseTracking();
    };
  }, [enabled, viewportRef, setHoldActive]);
}
