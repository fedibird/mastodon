import {
  assignMasonryPrependedColumns,
  isFullWidthMasonryKey,
  leadingMasonryPrefixKeys,
  reconcileMasonryPrepends,
} from '../timeline_masonry_layout';

const heights = { A: 90, B: 130, C: 70, D: 180, E: 100, F: 140, G: 120 };
const height = key => heights[key] || 100;

describe('streaming masonry shortest-column placement', () => {
  it('distinguishes a prepend from a first load, older-page append, or middle insertion', () => {
    expect(reconcileMasonryPrepends([], ['A', 'B'])).toEqual({
      prefixKeys: [], prependedKeys: [], reset: false,
    });
    expect(reconcileMasonryPrepends(['A', 'B'], ['D', 'A', 'B'])).toEqual({
      prefixKeys: [], prependedKeys: ['D'], reset: false,
    });
    expect(reconcileMasonryPrepends(['A', 'B'], ['E', 'D', 'A', 'B', 'older'])).toEqual({
      prefixKeys: [], prependedKeys: ['E', 'D'], reset: false,
    });
    expect(reconcileMasonryPrepends(['A', 'B'], ['A', 'inserted', 'B'])).toEqual({
      prefixKeys: [], prependedKeys: [], reset: false,
    });
    expect(reconcileMasonryPrepends(['A', 'B'], ['A', 'B', 'older'])).toEqual({
      prefixKeys: [], prependedKeys: [], reset: false,
    });
  });

  it('preserves the pinned/reload prefix and resets only when the prefix changes', () => {
    const previous = ['.$reload', '.$f-pinned', '.$A', '.$B'];
    const prefix = ['.$reload', '.$f-pinned'];

    expect(leadingMasonryPrefixKeys(previous)).toEqual(prefix);
    expect(reconcileMasonryPrepends(previous, [
      '.$reload', '.$f-pinned', '.$D', '.$A', '.$B',
    ], prefix)).toEqual({
      prefixKeys: prefix, prependedKeys: ['.$D'], reset: false,
    });
    expect(reconcileMasonryPrepends(prefix, [
      '.$reload', '.$f-pinned', '.$A', '.$B',
    ], prefix).prependedKeys).toEqual(['.$A', '.$B']);
    expect(reconcileMasonryPrepends(previous, [
      '.$f-other', '.$A', '.$B',
    ], prefix).reset).toBe(true);
  });

  it('resets when the timeline identity changes or existing items reorder', () => {
    expect(reconcileMasonryPrepends(['A', 'B'], ['A', 'C']).reset).toBe(false);
    expect(reconcileMasonryPrepends(['A', 'B'], ['X', 'Y']).reset).toBe(true);
    expect(reconcileMasonryPrepends(['A', 'B'], ['B', 'A']).reset).toBe(true);
    expect(reconcileMasonryPrepends(['A', 'B'], []).reset).toBe(true);
  });

  it('recognizes full-width barriers after React key escaping', () => {
    expect(isFullWidthMasonryKey('.$gap:123')).toBe(true);
    expect(isFullWidthMasonryKey('.$gap=2123')).toBe(true);
    expect(isFullWidthMasonryKey('.$gap=02123')).toBe(true);
    expect(isFullWidthMasonryKey('.$more:older')).toBe(true);
    expect(isFullWidthMasonryKey('.$more=2older')).toBe(true);
    expect(isFullWidthMasonryKey('.$media:123:0')).toBe(false);
  });

  it('chooses the shortest existing column then updates the height after each new tile', () => {
    const assigned = new Map([['A', 0], ['B', 1], ['C', 2]]);
    assignMasonryPrependedColumns(3, ['A', 'B', 'C'], ['G', 'F', 'E', 'D'], assigned, height);

    expect(['D', 'E', 'F', 'G'].map(key => assigned.get(key))).toEqual([2, 0, 1, 0]);
    expect(['A', 'B', 'C'].map(key => assigned.get(key))).toEqual([0, 1, 2]);
  });

  it('uses inline-end first when heights tie, in both two and three columns', () => {
    const assigned3 = new Map([['A', 0], ['B', 1], ['C', 2]]);
    assignMasonryPrependedColumns(3, ['A', 'B', 'C'], ['F', 'E', 'D'], assigned3, () => 100);
    expect(['D', 'E', 'F'].map(key => assigned3.get(key))).toEqual([2, 1, 0]);

    const assigned2 = new Map([['A', 0], ['B', 1]]);
    assignMasonryPrependedColumns(2, ['A', 'B'], ['E', 'D'], assigned2, () => 100);
    expect(['D', 'E'].map(key => assigned2.get(key))).toEqual([1, 0]);
  });

  it('gives the same columns for a measured batch and individually measured arrivals', () => {
    const old = ['A', 'B', 'C'];
    const batch = new Map([['A', 0], ['B', 1], ['C', 2]]);
    const individual = new Map(batch);
    assignMasonryPrependedColumns(3, old, ['G', 'F', 'E', 'D'], batch, height);

    let current = old;
    for (const key of ['D', 'E', 'F', 'G']) {
      assignMasonryPrependedColumns(3, current, [key], individual, height);
      current = [key, ...current];
    }

    expect(Array.from(batch.entries())).toEqual(Array.from(individual.entries()));
  });

  it('stops counting old heights at the first full-width row and restarts after a new one', () => {
    const assigned = new Map([['A', 0], ['B', 1], ['C', 2]]);
    // B and C occur below a full-width gap and are not in the active segment.
    assignMasonryPrependedColumns(3, ['A', 'gap:old', 'B', 'C'], ['D'], assigned, height);
    expect(assigned.get('D')).toBe(2);

    const split = new Map([['A', 0], ['B', 1]]);
    assignMasonryPrependedColumns(3, ['A', 'B'], ['D', 'gap:new', 'E'], split, height);
    expect(split.get('E')).toBe(2);
    expect(split.get('D')).toBe(2);
    expect(split.has('gap:new')).toBe(false);
  });

  it('does not change assigned columns after existing height measurements change', () => {
    const assigned = new Map([['A', 0], ['B', 1], ['C', 2]]);
    assignMasonryPrependedColumns(3, ['A', 'B', 'C'], ['D'], assigned, height);
    const snapshot = Array.from(assigned.entries());

    // Heights are read for deciding a *new* arrival only, not retroactively.
    assignMasonryPrependedColumns(3, ['D', 'A', 'B', 'C'], [], assigned, () => 500);
    expect(Array.from(assigned.entries())).toEqual(snapshot);
  });
});
