// React.Children.toArray escapes ':' as '=2' in child keys.
const decodedReactKey = key => {
  // React.Children.map and Children.toArray can escape an already escaped
  // key. Decode repeatedly so full-width gap and featured keys are recognized
  // regardless of how many list wrappers have processed them.
  let value = String(key);

  for (let i = 0; i < 4; i += 1) {
    const decoded = value.replace(/=0/g, '=').replace(/=2/g, ':');
    if (decoded === value) {
      break;
    }
    value = decoded;
  }

  return value;
};

export const isFullWidthMasonryKey = key => /(?:^|[.$/])(?:gap|more):/.test(decodedReactKey(key));

// Featured statuses and the iOS reload control precede the live timeline.
export const isMasonryPrefixKey = key => /(?:^|[.$/])(?:f-|reload(?:$|[.:/]))/.test(decodedReactKey(key));

export const leadingMasonryPrefixKeys = keys => {
  const prefix = [];

  for (const key of keys) {
    if (!isMasonryPrefixKey(key)) {
      break;
    }
    prefix.push(key);
  }

  return prefix;
};

const sameKeys = (a, b) => a.length === b.length && a.every((key, index) => key === b[index]);

// Only a contiguous run before the first surviving old item counts as a
// streaming prepend. Older page loads, removals, and middle insertions do not.
export const reconcileMasonryPrepends = (previousKeys, keys, previousPrefixKeys = []) => {
  const prefixKeys = leadingMasonryPrefixKeys(keys);
  const empty = reset => ({ prefixKeys, prependedKeys: [], reset });

  if (previousKeys.length === 0) {
    return empty(false);
  }

  if (!sameKeys(previousPrefixKeys, prefixKeys)) {
    return empty(true);
  }

  const previousMainKeys = previousKeys.slice(previousPrefixKeys.length);
  const currentMainKeys = keys.slice(prefixKeys.length);

  if (previousMainKeys.length === 0) {
    // A previously prefix-only timeline has received its first live items.
    return { prefixKeys, prependedKeys: currentMainKeys, reset: false };
  }

  const currentKeys = new Set(currentMainKeys);
  const previousKeySet = new Set(previousMainKeys);
  const survivingPrevious = previousMainKeys.filter(key => currentKeys.has(key));
  const survivingCurrent = currentMainKeys.filter(key => previousKeySet.has(key));

  // A different feed, or one in which existing items were reordered, must
  // discard the old per-key columns.
  if (survivingPrevious.length === 0 || !sameKeys(survivingPrevious, survivingCurrent)) {
    return empty(true);
  }

  const firstOldIndex = currentMainKeys.findIndex(key => previousKeySet.has(key));
  return { prefixKeys, prependedKeys: currentMainKeys.slice(0, firstOldIndex), reset: false };
};

// Streaming cards grow *upward* from the original live-feed boundary.
// Each column has a frontier ("head"): the top of the oldest reserved space.
// A newly received card occupies the lowest available frontier, with logical
// inline-end winning ties. Frontiers are independent, but the outer Masonry
// reserves the maximum upward overflow for *every* column. Blank intervals
// become inert placeholders, to be consumed by subsequent arrivals.
//
// Coordinates returned here are relative to the top of that shared reserved
// area. Columns assigned to existing keys never change after measurements.
export const planMasonryPrependFrontier = (columns, keys, assignments, measuredHeight, gap = 8) => {
  const heads = new Array(columns).fill(0);
  const positions = new Map();
  const blanks = [];

  const reserveBlankCells = (top, barrier) => {
    heads.forEach((bottom, column) => {
      if (bottom - top > 1) {
        blanks.push({ key: barrier + ':' + column, top, column, height: bottom - top });
      }
    });
  };

  // The older card is inserted first: this fills available placeholders
  // before allocating additional common headroom above the whole feed.
  for (let index = keys.length - 1; index >= 0; index -= 1) {
    const key = keys[index];
    const height = measuredHeight(key) + gap;

    if (isFullWidthMasonryKey(key)) {
      const top = Math.min(...heads);
      reserveBlankCells(top, key);
      heads.fill(top - height);
      positions.set(key, { top: top - height, fullWidth: true });
      continue;
    }

    let column = assignments.get(key);
    if (column === undefined || column < 0 || column >= columns) {
      column = columns - 1;
      for (let candidate = columns - 2; candidate >= 0; candidate -= 1) {
        // Largest Y is the lowest available position for a new item.
        if (heads[candidate] > heads[column]) {
          column = candidate;
        }
      }
      assignments.set(key, column);
    }

    heads[column] -= height;
    positions.set(key, { top: heads[column], column });
  }

  const highestTop = Math.min(...heads);
  reserveBlankCells(highestTop, 'leading');
  const overflow = -highestTop;

  return {
    positions: new Map(Array.from(positions, ([key, place]) => [
      key, { ...place, top: place.top + overflow },
    ])),
    placeholders: blanks.map(blank => ({ ...blank, top: blank.top + overflow })),
    height: overflow,
  };
};

// Masonry keeps logical newest-first DOM order, while the tiles' actual
// viewport positions are independent in each column. A generic binary search
// over article DOM order therefore cannot choose a stable reading anchor.
// Share this visual selection between streaming and filter reconciliation.
export const findVisibleMasonryTile = (root, visibleTop, visibleBottom) => {
  if (!root || typeof root.querySelectorAll !== 'function') {
    return null;
  }

  let best = null;
  root.querySelectorAll('.timeline-masonry > .timeline-masonry__item[data-layout-key]').forEach(node => {
    const key = node.getAttribute('data-layout-key');
    const box = node.getBoundingClientRect();
    if (!key || box.bottom <= visibleTop || box.top >= visibleBottom || box.height <= 0) {
      return;
    }

    const coversEdge = box.top <= visibleTop;
    const distance = coversEdge ? visibleTop - box.top : box.top - visibleTop;
    if (!best || (coversEdge && !best.coversEdge) ||
        (coversEdge === best.coversEdge && distance < best.distance)) {
      best = { node, key, top: box.top, coversEdge, distance };
    }
  });

  return best ? { node: best.node, key: best.key, top: best.top } : null;
};
