export const DRAG_THRESHOLD = 8;
export const LONG_PRESS_DELAY = 450;

export function pointerPastThreshold(origin, point, threshold = DRAG_THRESHOLD) {
  if (!origin || !point) {
    return false;
  }

  const dx = point.x - origin.x;
  const dy = point.y - origin.y;

  return Math.hypot(dx, dy) >= threshold;
}

export function insertionIndexForPoint(rects, x, y) {
  if (!rects || rects.length === 0) {
    return 0;
  }

  let closestIndex = rects.length;
  let closestDistance = Infinity;

  rects.forEach((rect, index) => {
    const centerY = rect.top + (rect.height / 2);
    const edges = [
      { x: rect.left, y: centerY, index },
      { x: rect.right, y: centerY, index: index + 1 },
    ];

    edges.forEach((edge) => {
      const distance = ((edge.x - x) ** 2) + ((edge.y - y) ** 2);

      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = edge.index;
      }
    });
  });

  return closestIndex;
}

export function preferredDropIndex(fullValues, visibleValues, visibleIndex, draggedValue) {
  const remaining = fullValues.filter(value => value !== draggedValue);
  const visible = visibleValues.filter(value => value !== draggedValue);
  const index = Number.isFinite(visibleIndex) ? visibleIndex : visible.length;

  if (index >= visible.length) {
    return remaining.length;
  }

  const anchor = visible[Math.max(0, index)];
  const anchorIndex = remaining.indexOf(anchor);

  return anchorIndex === -1 ? remaining.length : anchorIndex;
}

export function pointWithinRect(rect, x, y) {
  if (!rect) {
    return false;
  }

  return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
}
