// Geometry only. No status/filter interpretation, observers or perpetual rAF.
export const captureFilterAnchor = (node, scroller, top) => {
  if (!node || !scroller) return null;
  const rows = Array.from(node.querySelectorAll('article[data-id]'));
  const rects = rows.map(row => ({ row, rect: row.getBoundingClientRect() }));
  const index = rects.findIndex(({ rect }) => rect.height > 0 && rect.bottom > top);
  // Keep nearby alternatives if the reading row itself disappears.
  const nearby = index < 0 ? [] : [index, index + 1, index + 2, index - 1, index - 2];
  return {
    offset: scroller.scrollTop,
    rows: nearby.filter(i => i >= 0 && i < rects.length).map(i => ({ node: rects[i].row, offset: rects[i].rect.top - top })),
    focused: node.contains(document.activeElement) ? document.activeElement : null,
  };
};

export const restoreFilterAnchor = (snapshot, node, scroller, top) => {
  if (!snapshot || !node || !scroller) return;
  const anchor = snapshot.rows.find(row => node.contains(row.node) && row.node.getBoundingClientRect().height > 0);
  if (anchor) scroller.scrollTop += anchor.node.getBoundingClientRect().top - top - anchor.offset;
  else scroller.scrollTop = snapshot.offset;
  if (snapshot.focused && !node.contains(snapshot.focused)) {
    const target = anchor?.node || node;
    target.focus({ preventScroll: true });
  }
};
