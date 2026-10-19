import { isProgrammaticTopScroll } from '../scroll';

// Geometry only. No status/filter interpretation, observers or perpetual rAF.

export const captureFilterAnchor = (node, scroller, top) => {
  if (!node || !scroller) return null;
  const rows = Array.from(node.querySelectorAll('article[data-id]'));
  // Articles are in vertical document order, including zero-height hidden
  // rows and virtual placeholders. Locate the reading edge with O(log n)
  // rect reads, then retain only a small, bounded neighborhood.
  const rects = new Map();
  const rect = i => {
    if (!rects.has(i)) rects.set(i, rows[i].getBoundingClientRect());
    return rects.get(i);
  };
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const mid = Math.floor((low + high) / 2);
    if (rect(mid).bottom > top) high = mid;
    else low = mid + 1;
  }
  const nearby = [];
  for (let i = low; i < Math.min(rows.length, low + 5); i++) {
    if (rect(i).height > 0) nearby.push(i);
  }
  for (let i = low - 1; i >= Math.max(0, low - 2); i--) {
    if (rect(i).height > 0) nearby.push(i);
  }
  return {
    offset: scroller.scrollTop,
    rows: nearby.map(i => ({ node: rows[i], offset: rect(i).top - top })),
    focused: node.contains(document.activeElement) ? document.activeElement : null,
  };
};

// A scroll smaller than this is the same tolerance as a layout write. The
// stale check used to allow a full pixel, so a 0.6–1px inertia step was
// written back and the native momentum stopped.
const POSITION_EPSILON = 0.5;

export const restoreFilterAnchor = (snapshot, node, scroller, top) => {
  if (!snapshot || !node || !scroller || snapshot.abandoned) return;
  // Travel is user momentum or a scrollbar move. A layout change leaves
  // scrollTop where the snapshot recorded it and only moves row rects.
  // Any travel outside the epsilon makes the snapshot stale, including
  // when the row rect merely follows that travel. Our own correction
  // updates snapshot.offset, so the next frame is not treated as travel.
  const travel = scroller.scrollTop - snapshot.offset;
  if (isProgrammaticTopScroll(scroller) || Math.abs(travel) > POSITION_EPSILON) {
    snapshot.abandoned = true;
    return;
  }
  const anchor = snapshot.rows.find(row => node.contains(row.node) && row.node.getBoundingClientRect().height > 0);
  if (anchor) {
    const delta = anchor.node.getBoundingClientRect().top - top - anchor.offset;
    if (Math.abs(delta) > POSITION_EPSILON) {
      scroller.scrollTop += delta;
      snapshot.offset = scroller.scrollTop;
    }
  }
  if (snapshot.focused && !node.contains(snapshot.focused)) {
    const target = anchor?.node || node;
    target.focus({ preventScroll: true });
  }
};
