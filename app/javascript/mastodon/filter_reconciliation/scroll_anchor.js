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

export const restoreFilterAnchor = (snapshot, node, scroller, top) => {
  if (!snapshot || !node || !scroller || snapshot.abandoned) return;
  // A later frame must not treat the correction we just wrote as a user
  // scroll. Movement after the snapshot, including scrollbar and momentum
  // that never reach a pointer listener, makes the snapshot stale.
  if (isProgrammaticTopScroll(scroller) || Math.abs(scroller.scrollTop - snapshot.offset) > 1) {
    snapshot.abandoned = true;
    return;
  }
  const anchor = snapshot.rows.find(row => node.contains(row.node) && row.node.getBoundingClientRect().height > 0);
  if (anchor) {
    const delta = anchor.node.getBoundingClientRect().top - top - anchor.offset;
    if (Math.abs(delta) > 0.5) {
      scroller.scrollTop += delta;
      snapshot.offset = scroller.scrollTop;
    }
  }
  if (snapshot.focused && !node.contains(snapshot.focused)) {
    const target = anchor?.node || node;
    target.focus({ preventScroll: true });
  }
};
