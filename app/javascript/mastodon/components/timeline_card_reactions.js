import React from 'react';
import PropTypes from 'prop-types';

const OVERFLOW_EPSILON = 1;

export function showCardEmojiReactions (enableReactionFlag, hasVisibleReactions, compactReactionFlag) {
  return Boolean(enableReactionFlag) && Boolean(hasVisibleReactions) && !compactReactionFlag;
}

export default function TimelineCardReactions ({ children, singleLine = true, expandLabel, scrollLabel }) {
  const [expanded, setExpanded] = React.useState(false);
  const [overflowing, setOverflowing] = React.useState(false);
  const scrollRef = React.useRef(null);
  const trackRef = React.useRef(null);
  const wrapped = !singleLine || expanded;

  const measureOverflow = React.useCallback(() => {
    if (wrapped || !scrollRef.current) {
      return;
    }

    const scroller = scrollRef.current;
    const hasHiddenReactions = scroller.scrollWidth - scroller.clientWidth > OVERFLOW_EPSILON;
    setOverflowing(previous => previous === hasHiddenReactions ? previous : hasHiddenReactions);
  }, [wrapped]);

  React.useLayoutEffect(measureOverflow);

  React.useEffect(() => {
    if (wrapped) {
      return undefined;
    }

    const scroller = scrollRef.current;
    const track = trackRef.current;
    if (!scroller || !track) {
      return undefined;
    }

    if (window.ResizeObserver) {
      const resizeObserver = new window.ResizeObserver(measureOverflow);
      resizeObserver.observe(scroller);
      resizeObserver.observe(track);
      return () => resizeObserver.disconnect();
    }

    window.addEventListener('resize', measureOverflow);
    return () => window.removeEventListener('resize', measureOverflow);
  }, [wrapped, measureOverflow]);

  // Keep keyboard focus when the expand button unmounts. Do not scroll the
  // timeline just because the reaction row grew.
  React.useEffect(() => {
    if (expanded && scrollRef.current) {
      scrollRef.current.focus({ preventScroll: true });
    }
  }, [expanded]);

  const handleExpand = React.useCallback(event => {
    event.preventDefault();
    event.stopPropagation();
    setExpanded(true);
  }, []);

  const canScrollInline = singleLine && !expanded && overflowing;
  let scrollTabIndex;
  if (canScrollInline) {
    scrollTabIndex = 0;
  } else if (expanded) {
    scrollTabIndex = -1;
  }

  return (
    <div className={`timeline-card__reactions${wrapped ? ' timeline-card__reactions--wrapped' : ' timeline-card__reactions--single'}`}>
      <div
        ref={scrollRef}
        className='timeline-card__reactions-scroll'
        tabIndex={scrollTabIndex}
        aria-label={canScrollInline ? scrollLabel : undefined}
      >
        <div ref={trackRef} className='timeline-card__reactions-track'>
          {children}
        </div>
      </div>
      {canScrollInline && (
        <button type='button' className='timeline-card__expand timeline-card__reactions-expand' onClick={handleExpand} aria-label={expandLabel} title={expandLabel}>
          <span aria-hidden='true'>▼</span>
        </button>
      )}
    </div>
  );
}

TimelineCardReactions.propTypes = {
  children: PropTypes.node,
  singleLine: PropTypes.bool,
  expandLabel: PropTypes.string.isRequired,
  scrollLabel: PropTypes.string.isRequired,
};
