// Every streaming prepend occupies a reserved row above the old masonry.
// Its cells fill in logical end-to-start order; existing card columns remain
// unchanged. React.Children.toArray escapes ':' as '=2' in child keys.
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
// Keep this stable prefix above reserved rows.
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

const emptyPlan = prefixKeys => ({ rows: [], prefixKeys });
const sameKeys = (a, b) => a.length === b.length && a.every((key, index) => key === b[index]);

export const reconcileMasonryPrependRows = (columns, previousKeys, keys, previousRows, previousPrefixKeys = []) => {
  const prefixKeys = leadingMasonryPrefixKeys(keys);

  if (columns < 2 || previousKeys.length === 0 || keys.length === 0) {
    return emptyPlan(prefixKeys);
  }

  // A pinned or reload prefix changing is not a live prepend. The new prefix
  // starts a fresh masonry layout at the next render.
  if (!sameKeys(previousPrefixKeys, prefixKeys)) {
    return emptyPlan(prefixKeys);
  }

  const previousMainKeys = previousKeys.slice(previousPrefixKeys.length);
  const currentMainKeys = keys.slice(prefixKeys.length);
  const currentKeys = new Set(currentMainKeys);
  const previousKeySet = new Set(previousMainKeys);
  const survivingPrevious = previousMainKeys.filter(key => currentKeys.has(key));
  const survivingCurrent = currentMainKeys.filter(key => previousKeySet.has(key));

  // Reject an identity switch or a reorder of existing cards. Older pages can
  // append without changing streaming reservations.
  if (survivingPrevious.length === 0 || !sameKeys(survivingPrevious, survivingCurrent)) {
    return emptyPlan(prefixKeys);
  }

  const firstOldIndex = currentMainKeys.findIndex(key => previousKeySet.has(key));

  const rows = previousRows.map(row => {
    if (row.kind === 'full') {
      return currentKeys.has(row.key) ? row : null;
    }

    return {
      ...row,
      slots: row.slots.map(key => currentKeys.has(key) ? key : null),
    };
  }).filter(row => row && (row.kind === 'full' || row.slots.some(Boolean)));

  // New keys are newest-first. The oldest newly received card enters the end
  // column first, and the newest takes the next available column toward start.
  for (let index = firstOldIndex - 1; index >= 0; index -= 1) {
    const key = currentMainKeys[index];

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

  return { rows, prefixKeys };
};
