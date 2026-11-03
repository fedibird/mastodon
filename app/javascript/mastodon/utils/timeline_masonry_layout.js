// Streaming statuses are assigned to reserved rows above the old masonry.
// A stable prefix (pinned posts or reload controls) can precede the stream.
export const isFullWidthMasonryKey = key => key.includes('gap:') || key.includes('more:');

const emptyPlan = () => ({ rows: [], prefixKeys: [] });

export const reconcileMasonryPrependRows = (columns, previousKeys, keys, previousRows, previousPrefixKeys = []) => {
  if (columns < 2 || previousKeys.length === 0 || keys.length === 0) {
    return emptyPlan();
  }

  const currentKeys = new Set(keys);
  const previousKeySet = new Set(previousKeys);
  const survivingPrevious = previousKeys.filter(key => currentKeys.has(key));
  const survivingCurrent = keys.filter(key => previousKeySet.has(key));

  // The timeline changed identity or reordered old items, rather than merely
  // receiving new statuses. Do not reuse placements from another snapshot.
  if (survivingPrevious.length === 0 || survivingPrevious.some((key, index) => key !== survivingCurrent[index])) {
    return emptyPlan();
  }

  let prefixKeys = previousRows.length > 0 ? previousPrefixKeys : [];

  if (prefixKeys.some((key, index) => keys[index] !== key)) {
    return emptyPlan();
  }

  let start = prefixKeys.length;

  if (previousRows.length === 0) {
    // The first new status may follow a stable group of featured posts or an
    // iOS reload control. Its insertion still counts as a stream prepend.
    start = keys.findIndex(key => !previousKeySet.has(key));
    if (start < 0 || !keys.slice(start + 1).some(key => previousKeySet.has(key))) {
      return emptyPlan();
    }

    prefixKeys = keys.slice(0, start);
  }

  const firstOldIndex = keys.findIndex((key, index) => index >= start && previousKeySet.has(key));

  if (firstOldIndex < 0) {
    return emptyPlan();
  }

  const rows = previousRows.map(row => {
    if (row.kind === 'full') {
      return currentKeys.has(row.key) ? row : null;
    }

    return {
      ...row,
      slots: row.slots.map(key => currentKeys.has(key) ? key : null),
    };
  }).filter(row => row && (row.kind === 'full' || row.slots.some(Boolean)));

  // New keys are in newest-first DOM order. Consume oldest-first, so a row
  // fills from the logical end column toward the logical start column.
  for (let index = firstOldIndex - 1; index >= start; index -= 1) {
    const key = keys[index];

    if (isFullWidthMasonryKey(key)) {
      rows.unshift({ kind: 'full', key });
      continue;
    }

    if (rows.length === 0 || rows[0].kind !== 'slots' || rows[0].nextColumn < 0) {
      rows.unshift({
        kind: 'slots',
        slots: new Array(columns).fill(null),
        nextColumn: columns - 1,
      });
    }

    const currentRow = rows[0];
    currentRow.slots[currentRow.nextColumn] = key;
    currentRow.nextColumn -= 1;
  }

  return rows.length > 0 ? { rows, prefixKeys } : emptyPlan();
};
