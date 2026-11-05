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

// Place newly arrived items oldest first, repeatedly taking the column with
// the least occupied height. On a tie use logical inline-end (the last index).
// The caller supplies measurements when known, or estimated tile heights.
// Assignments are never reconsidered when a later ResizeObserver event arrives.
export const assignMasonryPrependedColumns = (columns, olderKeys, prependedKeys, assignments, measuredHeight, gap = 8) => {
  const bottoms = new Array(columns).fill(0);

  // A full-width gap/more row separates independent masonry segments. Items
  // below the first barrier cannot bias a new item placed above that barrier.
  for (const key of olderKeys) {
    if (isFullWidthMasonryKey(key)) {
      break;
    }

    const column = assignments.get(key);
    if (column !== undefined && column >= 0 && column < columns) {
      bottoms[column] += measuredHeight(key) + gap;
    }
  }

  for (let index = prependedKeys.length - 1; index >= 0; index -= 1) {
    const key = prependedKeys[index];

    if (isFullWidthMasonryKey(key)) {
      bottoms.fill(0);
      continue;
    }

    let column = columns - 1;
    for (let candidate = columns - 2; candidate >= 0; candidate -= 1) {
      if (bottoms[candidate] < bottoms[column]) {
        column = candidate;
      }
    }

    assignments.set(key, column);
    bottoms[column] += measuredHeight(key) + gap;
  }

  return assignments;
};
