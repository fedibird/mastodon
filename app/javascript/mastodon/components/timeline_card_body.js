import React from 'react';
import PropTypes from 'prop-types';

import { elementDirection, findTimelineScroller, isInlineEndZone, wheelDeltaY } from './timeline_scroll_zone';

// The toggle takes 30px of height plus 2px top margin. Showing it for
// a smaller overflow can make the card *shrink* when the toggle disappears.
// The CSS height guide tracks the ten-line viewport plus that toggle footprint.
const EXPAND_BUTTON_FOOTPRINT = 32;
const EXPANSION_EPSILON = 1;
const TOUCH_SLOP = 8;

export default function TimelineCardBody ({ children, expandLabel, scrollLabel, collapseLongText = true, timelineScrollZone = true, scrollZoneLabel }) {
  const [expanded, setExpanded] = React.useState(false);
  const [needsCollapse, setNeedsCollapse] = React.useState(false);
  const viewportRef = React.useRef(null);
  const contentRef = React.useRef(null);
  const foldedHeightRef = React.useRef(null);

  const measureCollapse = React.useCallback(() => {
    if (!collapseLongText) {
      setNeedsCollapse(previous => previous ? false : previous);
      return;
    }

    if (expanded || !viewportRef.current) {
      return;
    }

    const viewport = viewportRef.current;
    // The guide has the height of a capped body INCLUDING its expand button.
    // It remains measurable even when the body is showing its natural height,
    // so a slight overflow never causes a collapse/expand measurement loop.
    const measuredFoldedHeight = foldedHeightRef.current?.getBoundingClientRect().height;
    const foldedHeight = measuredFoldedHeight > 0
      ? measuredFoldedHeight
      : viewport.clientHeight + EXPAND_BUTTON_FOOTPRINT;
    const shouldCollapse = viewport.scrollHeight - foldedHeight > EXPANSION_EPSILON;
    setNeedsCollapse(previous => previous === shouldCollapse ? previous : shouldCollapse);
  }, [collapseLongText, expanded]);

  // Recheck after status/CW/translation changes, including a rerender that does
  // not resize the outer card while its body is capped.
  React.useLayoutEffect(measureCollapse);

  React.useEffect(() => {
    if (!collapseLongText || expanded) {
      return undefined;
    }

    const viewport = viewportRef.current;
    const content = contentRef.current;
    const foldedHeight = foldedHeightRef.current;
    if (!viewport || !content || !foldedHeight) {
      return undefined;
    }

    if (window.ResizeObserver) {
      const resizeObserver = new window.ResizeObserver(measureCollapse);
      resizeObserver.observe(viewport);
      resizeObserver.observe(content);
      resizeObserver.observe(foldedHeight);
      return () => resizeObserver.disconnect();
    }

    // Only old browsers need a global resize listener. The observer monitors
    // the content and capped viewport (the height guide is covered by resize).
    window.addEventListener('resize', measureCollapse);
    return () => window.removeEventListener('resize', measureCollapse);
  }, [collapseLongText, expanded, measureCollapse]);

  // Do not drop keyboard focus when the expand button unmounts.
  React.useEffect(() => {
    if (expanded && viewportRef.current) {
      viewportRef.current.focus({ preventScroll: true });
    }
  }, [expanded]);

  const scrollable = collapseLongText && !expanded && needsCollapse;
  const showScrollZone = scrollable && timelineScrollZone;

  React.useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport || !showScrollZone) {
      return undefined;
    }

    const inZone = clientX => isInlineEndZone(clientX, viewport.getBoundingClientRect(), elementDirection(viewport));

    const onWheel = event => {
      if (event.ctrlKey || event.metaKey) {
        return;
      }

      if (Math.abs(event.deltaX || 0) > Math.abs(event.deltaY || 0)) {
        return;
      }

      if (!inZone(event.clientX)) {
        return;
      }

      const scroller = findTimelineScroller(viewport);
      if (!scroller || scroller === viewport) {
        return;
      }

      event.preventDefault();
      stopMomentum();
      scroller.scrollTop += wheelDeltaY(event);
    };

    // A tap still clicks the text underneath. Only a vertical drag in the
    // inline-end third is handed to the timeline.
    let gesture = null;
    let momentumFrame = null;
    const stopMomentum = () => {
      if (momentumFrame !== null && window.cancelAnimationFrame) {
        window.cancelAnimationFrame(momentumFrame);
      }
      momentumFrame = null;
    };

    const startMomentum = (scroller, initialVelocity) => {
      if (!window.requestAnimationFrame) {
        return;
      }

      let velocity = initialVelocity;
      let previousFrame = performance.now();
      const step = now => {
        momentumFrame = null;
        const elapsed = Math.max(0, Math.min(32, now - previousFrame));
        previousFrame = now;
        const before = scroller.scrollTop;
        scroller.scrollTop += velocity * elapsed;
        // The scroll host clamps at either end; stop instead of spinning.
        if (Math.abs(scroller.scrollTop - before) < 0.5) {
          return;
        }

        velocity *= Math.pow(0.92, elapsed / 16);
        if (Math.abs(velocity) >= 0.08) {
          momentumFrame = window.requestAnimationFrame(step);
        }
      };
      momentumFrame = window.requestAnimationFrame(step);
    };

    const onTouchStart = event => {
      stopMomentum();
      if (!event.touches || event.touches.length !== 1) {
        gesture = null;
        return;
      }

      const touch = event.touches[0];
      if (!inZone(touch.clientX)) {
        gesture = null;
        return;
      }

      gesture = { x: touch.clientX, y: touch.clientY, handedOff: false, lastMoveAt: performance.now(), velocity: 0, scroller: null };
    };

    const onTouchMove = event => {
      if (!gesture) {
        return;
      }

      // A second finger belongs to the browser (pinch/zoom), never to this
      // timeline handoff. Discard the tracked gesture until the next start.
      if (!event.touches || event.touches.length !== 1) {
        gesture = null;
        return;
      }

      const touch = event.touches[0];
      const dx = touch.clientX - gesture.x;
      const dy = touch.clientY - gesture.y;

      if (!gesture.handedOff) {
        if (Math.abs(dy) < TOUCH_SLOP || Math.abs(dy) < Math.abs(dx)) {
          return;
        }

        gesture.handedOff = true;
      }

      const scroller = findTimelineScroller(viewport);
      if (!scroller || scroller === viewport) {
        return;
      }

      if (event.cancelable) {
        event.preventDefault();
      }

      // Preserve a modest fling after touchend. Programmatic scrollTop writes
      // do not inherit native momentum on iOS; cancel on new input or unmount.
      const now = performance.now();
      const elapsed = Math.max(8, Math.min(50, now - gesture.lastMoveAt));
      const instantaneousVelocity = Math.max(-3, Math.min(3, -dy / elapsed));
      gesture.velocity = gesture.velocity * 0.3 + instantaneousVelocity * 0.7;
      gesture.lastMoveAt = now;
      gesture.scroller = scroller;
      scroller.scrollTop -= dy;
      gesture.x = touch.clientX;
      gesture.y = touch.clientY;
    };

    const onTouchEnd = () => {
      if (gesture && gesture.handedOff && gesture.scroller &&
          performance.now() - gesture.lastMoveAt < 100 && Math.abs(gesture.velocity) > 0.1) {
        startMomentum(gesture.scroller, gesture.velocity);
      }
      gesture = null;
    };

    const onTouchCancel = () => {
      gesture = null;
      stopMomentum();
    };

    viewport.addEventListener('wheel', onWheel, { passive: false });
    viewport.addEventListener('touchstart', onTouchStart, { passive: true });
    viewport.addEventListener('touchmove', onTouchMove, { passive: false });
    viewport.addEventListener('touchend', onTouchEnd);
    viewport.addEventListener('touchcancel', onTouchCancel);

    return () => {
      viewport.removeEventListener('wheel', onWheel);
      viewport.removeEventListener('touchstart', onTouchStart);
      viewport.removeEventListener('touchmove', onTouchMove);
      viewport.removeEventListener('touchend', onTouchEnd);
      viewport.removeEventListener('touchcancel', onTouchCancel);
      stopMomentum();
    };
  }, [showScrollZone]);

  const handleExpand = React.useCallback(event => {
    // The card container itself navigates to the status on click.
    event.preventDefault();
    event.stopPropagation();
    setExpanded(true);
  }, []);

  let bodyTabIndex;
  if (scrollable) {
    bodyTabIndex = 0;
  } else if (expanded) {
    // Keep an explicit programmatic focus target after removing the button.
    bodyTabIndex = -1;
  }

  const zoneNote = showScrollZone && scrollZoneLabel ? scrollZoneLabel : null;
  const ariaLabel = scrollable ? [scrollLabel, zoneNote].filter(Boolean).join('. ') : undefined;
  const bodyClass = [
    'timeline-card__body',
    scrollable ? 'timeline-card__body--scrollable' : null,
    expanded ? 'timeline-card__body--expanded' : null,
    collapseLongText ? null : 'timeline-card__body--natural',
  ].filter(Boolean).join(' ');

  return (
    <div className={bodyClass}>
      <div ref={foldedHeightRef} className='timeline-card__body-folded-height' aria-hidden='true' />
      <div
        ref={viewportRef}
        className='timeline-card__body-scroll'
        role={scrollable || expanded ? 'group' : undefined}
        aria-label={ariaLabel}
        tabIndex={bodyTabIndex}
      >
        <div ref={contentRef}>{children}</div>
      </div>
      {scrollable && (
        <button type='button' className='timeline-card__expand' onClick={handleExpand} aria-label={expandLabel} title={expandLabel}>
          <span aria-hidden='true'>▼</span>
        </button>
      )}
    </div>
  );
}

TimelineCardBody.propTypes = {
  children: PropTypes.node,
  expandLabel: PropTypes.string.isRequired,
  scrollLabel: PropTypes.string.isRequired,
  collapseLongText: PropTypes.bool,
  timelineScrollZone: PropTypes.bool,
  scrollZoneLabel: PropTypes.string,
};
