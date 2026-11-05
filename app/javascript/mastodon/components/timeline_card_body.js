import React from 'react';
import PropTypes from 'prop-types';

import { elementDirection, findTimelineScroller, isInlineEndZone, wheelDeltaY } from './timeline_scroll_zone';

// Small rounding differences in scroll metrics must not create an expand button
// for text that fits entirely inside the ten-line viewport.
const OVERFLOW_EPSILON = 1;
const TOUCH_SLOP = 8;

export default function TimelineCardBody ({ children, expandLabel, scrollLabel, collapseLongText = true, timelineScrollZone = true, scrollZoneLabel }) {
  const [expanded, setExpanded] = React.useState(false);
  const [overflowing, setOverflowing] = React.useState(false);
  const viewportRef = React.useRef(null);
  const contentRef = React.useRef(null);

  const measureOverflow = React.useCallback(() => {
    if (!collapseLongText) {
      setOverflowing(previous => previous ? false : previous);
      return;
    }

    if (expanded || !viewportRef.current) {
      return;
    }

    const viewport = viewportRef.current;
    const hasHiddenText = viewport.scrollHeight - viewport.clientHeight > OVERFLOW_EPSILON;
    setOverflowing(previous => previous === hasHiddenText ? previous : hasHiddenText);
  }, [collapseLongText, expanded]);

  // Recheck after status/CW/translation changes, including a rerender that does
  // not resize the outer card while its body is capped.
  React.useLayoutEffect(measureOverflow);

  React.useEffect(() => {
    if (!collapseLongText || expanded) {
      return undefined;
    }

    const viewport = viewportRef.current;
    const content = contentRef.current;
    if (!viewport || !content) {
      return undefined;
    }

    if (window.ResizeObserver) {
      const resizeObserver = new window.ResizeObserver(measureOverflow);
      resizeObserver.observe(viewport);
      resizeObserver.observe(content);
      return () => resizeObserver.disconnect();
    }

    // Only old browsers need a global resize listener. The observer monitors
    // both the capped viewport and the natural height of the inner content.
    window.addEventListener('resize', measureOverflow);
    return () => window.removeEventListener('resize', measureOverflow);
  }, [collapseLongText, expanded, measureOverflow]);

  // Do not drop keyboard focus when the expand button unmounts.
  React.useEffect(() => {
    if (expanded && viewportRef.current) {
      viewportRef.current.focus({ preventScroll: true });
    }
  }, [expanded]);

  const scrollable = collapseLongText && !expanded && overflowing;
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
      scroller.scrollTop += wheelDeltaY(event);
    };

    // A tap still clicks the text underneath. Only a vertical drag in the
    // inline-end third is handed to the timeline.
    let gesture = null;

    const onTouchStart = event => {
      const touch = event.touches && event.touches[0];
      if (!touch || !inZone(touch.clientX)) {
        gesture = null;
        return;
      }

      gesture = { x: touch.clientX, y: touch.clientY, handedOff: false };
    };

    const onTouchMove = event => {
      if (!gesture) {
        return;
      }

      const touch = event.touches && event.touches[0];
      if (!touch) {
        return;
      }

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

      scroller.scrollTop -= dy;
      gesture.x = touch.clientX;
      gesture.y = touch.clientY;
    };

    const onTouchEnd = () => {
      gesture = null;
    };

    viewport.addEventListener('wheel', onWheel, { passive: false });
    viewport.addEventListener('touchstart', onTouchStart, { passive: true });
    viewport.addEventListener('touchmove', onTouchMove, { passive: false });
    viewport.addEventListener('touchend', onTouchEnd);
    viewport.addEventListener('touchcancel', onTouchEnd);

    return () => {
      viewport.removeEventListener('wheel', onWheel);
      viewport.removeEventListener('touchstart', onTouchStart);
      viewport.removeEventListener('touchmove', onTouchMove);
      viewport.removeEventListener('touchend', onTouchEnd);
      viewport.removeEventListener('touchcancel', onTouchEnd);
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
    expanded ? 'timeline-card__body--expanded' : null,
    collapseLongText ? null : 'timeline-card__body--natural',
  ].filter(Boolean).join(' ');

  return (
    <div className={bodyClass}>
      <div
        ref={viewportRef}
        className='timeline-card__body-scroll'
        role={scrollable || expanded ? 'group' : undefined}
        aria-label={ariaLabel}
        tabIndex={bodyTabIndex}
      >
        <div ref={contentRef}>{children}</div>
      </div>
      {showScrollZone && (
        <div className='timeline-card__scroll-zone' style={{ pointerEvents: 'none' }} data-timeline-scroll-zone='true' aria-hidden='true' />
      )}
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
