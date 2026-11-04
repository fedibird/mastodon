import React from 'react';
import PropTypes from 'prop-types';

// Small rounding differences in scroll metrics must not create an expand button
// for text that fits entirely inside the ten-line viewport.
const OVERFLOW_EPSILON = 1;

export default function TimelineCardBody ({ children, expandLabel, scrollLabel }) {
  const [expanded, setExpanded] = React.useState(false);
  const [overflowing, setOverflowing] = React.useState(false);
  const viewportRef = React.useRef(null);
  const contentRef = React.useRef(null);

  const measureOverflow = React.useCallback(() => {
    if (expanded || !viewportRef.current) {
      return;
    }

    const viewport = viewportRef.current;
    const hasHiddenText = viewport.scrollHeight - viewport.clientHeight > OVERFLOW_EPSILON;
    setOverflowing(previous => previous === hasHiddenText ? previous : hasHiddenText);
  }, [expanded]);

  // Recheck after status/CW/translation changes, including a rerender that does
  // not resize the outer card while its body is capped.
  React.useLayoutEffect(measureOverflow);

  React.useEffect(() => {
    if (expanded) {
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
  }, [expanded, measureOverflow]);

  // Do not drop keyboard focus when the expand button unmounts.
  React.useEffect(() => {
    if (expanded && viewportRef.current) {
      viewportRef.current.focus({ preventScroll: true });
    }
  }, [expanded]);

  const handleExpand = React.useCallback(event => {
    // The card container itself navigates to the status on click.
    event.preventDefault();
    event.stopPropagation();
    setExpanded(true);
  }, []);

  const scrollable = !expanded && overflowing;
  let bodyTabIndex;
  if (scrollable) {
    bodyTabIndex = 0;
  } else if (expanded) {
    // Keep an explicit programmatic focus target after removing the button.
    bodyTabIndex = -1;
  }

  return (
    <div className={`timeline-card__body${expanded ? ' timeline-card__body--expanded' : ''}`}>
      <div
        ref={viewportRef}
        className='timeline-card__body-scroll'
        role={scrollable || expanded ? 'group' : undefined}
        aria-label={scrollable ? scrollLabel : undefined}
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
};
