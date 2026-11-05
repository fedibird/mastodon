// The inline-end third of a collapsed card body is a vertical pass-through
// to the timeline scroller. It is not a horizontal scroller.

export const INLINE_END_FRACTION = 1 / 3;

export function isInlineEndZone (clientX, rect, direction) {
  if (!rect || !(rect.width > 0) || typeof clientX !== 'number') {
    return false;
  }

  const offset = clientX - rect.left;
  const endWidth = rect.width * INLINE_END_FRACTION;

  if (direction === 'rtl') {
    return offset <= endWidth;
  }

  return offset >= rect.width - endWidth;
}

export function elementDirection (element) {
  if (!element || typeof window.getComputedStyle !== 'function') {
    return 'ltr';
  }

  return window.getComputedStyle(element).direction === 'rtl' ? 'rtl' : 'ltr';
}

export function findTimelineScroller (node) {
  let current = node ? node.parentElement : null;

  while (current) {
    if (current.classList && current.classList.contains('scrollable')) {
      return current;
    }

    current = current.parentElement;
  }

  return document.scrollingElement || document.documentElement;
}

export function wheelDeltaY (event) {
  const delta = event.deltaY || 0;

  if (event.deltaMode === 1) {
    return delta * 16;
  }

  if (event.deltaMode === 2) {
    return delta * (window.innerHeight || 0);
  }

  return delta;
}
