// New streaming statuses occupy reserved rows above the previously laid-out
// masonry. Slots are filled from logical end to start, leaving existing cards
// in their original columns (and preserving DOM order separately).
export const isFullWidthMasonryKey = key => key.includes('gap:') || key.includes('more:');

export const reconcileMasonryPrependRows = (columns, previousKeys, keys, previousRows) => {
  if (columns < 2 || previousKeys.length === 0 || keys.length === 0) {
    return [];
  }

  const currentKeys = new Set(keys);
  const previousKeySet = new Set(previousKeys);
  const survivingPrevious = previousKeys.filter(key => currentKeys.has(key));
  const survivingCurrent = keys.filter(key => previousKeySet.has(key));

  // A timeline reset or reordering is not a prepend. Rebuild the ordinary
  // layout rather than attaching old reserved rows to a different feed.
  if (survivingPrevious.length === 0 || survivingPrevious.some((key, index) => key !== survivingCurrent[index])) {
    return [];
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

  const firstOldIndex = keys.findIndex(key => previousKeySet.has(key));

  // Inputs are newest-first. Fill oldest new arrivals first, so the newest
  // ends up toward logical start without shifting an already occupied slot.
  for (let index = firstOldIndex - 1; index >= 0; index -= 1) {
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

  return rows;
};
