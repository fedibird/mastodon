import React from 'react';
import PropTypes from 'prop-types';

import useCardBodyHoldScroll from './card_body_hold_scroll';

// The toggle takes 30px of height plus 2px top margin. Showing it for
// a smaller overflow can make the card *shrink* when the toggle disappears.
// The CSS height guide tracks the ten-line viewport plus that toggle footprint.
const EXPAND_BUTTON_FOOTPRINT = 32;
const EXPANSION_EPSILON = 1;

export default function TimelineCardBody ({ children, expandLabel, scrollLabel, collapseLongText = true }) {
  const [expanded, setExpanded] = React.useState(false);
  const [needsCollapse, setNeedsCollapse] = React.useState(false);
  const [holdActive, setHoldActive] = React.useState(false);
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
  // A normal swipe scrolls the timeline. A sustained press enables direct
  // dragging of this text viewport only until the finger/button is released.
  useCardBodyHoldScroll(viewportRef, scrollable, setHoldActive);

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

  const ariaLabel = scrollable ? scrollLabel : undefined;
  const bodyClass = [
    'timeline-card__body',
    scrollable ? 'timeline-card__body--scrollable' : null,
    scrollable && holdActive ? 'timeline-card__body--hold-active' : null,
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
};
