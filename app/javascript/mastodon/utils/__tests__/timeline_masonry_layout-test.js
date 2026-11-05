import {
  isFullWidthMasonryKey,
  leadingMasonryPrefixKeys,
  planMasonryPrependFrontier,
  reconcileMasonryPrepends,
} from '../timeline_masonry_layout';

const heights = { A: 90, B: 130, C: 70, D: 180, E: 100, F: 140, G: 120, 'gap:123': 40, 'media:1:0': 80, latest: 90 };
const height = key => heights[key] || 100;
const plan = (keys, assignments = new Map(), columns = 3) => (
  planMasonryPrependFrontier(columns, keys, assignments, height)
);

describe('streaming masonry upward-frontier placement', () => {
  it('distinguishes prepends from initial loads, older-page appends, and middle insertions', () => {
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

  it('reserves the same upward overflow across all columns after one end-column arrival', () => {
    const assigned = new Map();
    const first = plan(['D'], assigned);

    expect(assigned.get('D')).toBe(2);
    expect(first.height).toBe(188);
    expect(first.positions.get('D').top).toBe(0);
    expect(first.placeholders).toEqual([
      { key: 'leading:0', top: 0, column: 0, height: 188 },
      { key: 'leading:1', top: 0, column: 1, height: 188 },
    ]);
  });

  it('replaces existing headroom, only extending the shared top when needed', () => {
    const assigned = new Map();
    const first = plan(['D'], assigned);
    const second = plan(['E', 'D'], assigned);
    const third = plan(['F', 'E', 'D'], assigned);
    const fourth = plan(['G', 'F', 'E', 'D'], assigned);

    expect([first.height, second.height, third.height, fourth.height]).toEqual([188, 188, 188, 236]);
    expect(['D', 'E', 'F', 'G'].map(key => assigned.get(key))).toEqual([2, 1, 0, 1]);
    expect(second.positions.get('E').top).toBe(80);
    expect(third.positions.get('F').top).toBe(40);
    expect(['D', 'E', 'F', 'G'].map(key => fourth.positions.get(key).top)).toEqual([48, 128, 88, 0]);
    expect(fourth.placeholders).toEqual([
      { key: 'leading:0', top: 0, column: 0, height: 88 },
      { key: 'leading:2', top: 0, column: 2, height: 48 },
    ]);
  });

  it('selects logical end on height ties for three and two columns', () => {
    const assigned3 = new Map();
    planMasonryPrependFrontier(3, ['F', 'E', 'D'], assigned3, () => 100);
    expect(['D', 'E', 'F'].map(key => assigned3.get(key))).toEqual([2, 1, 0]);

    const assigned2 = new Map();
    planMasonryPrependFrontier(2, ['E', 'D'], assigned2, () => 100);
    expect(['D', 'E'].map(key => assigned2.get(key))).toEqual([1, 0]);
  });

  it('produces the same positions for individual and batched deliveries at the same heights', () => {
    const batch = new Map();
    const individual = new Map();
    const combined = plan(['G', 'F', 'E', 'D'], batch);
    let current = [];

    for (const key of ['D', 'E', 'F', 'G']) {
      current = [key, ...current];
      plan(current, individual);
    }

    const after = plan(current, individual);
    expect(Array.from(batch.entries())).toEqual(Array.from(individual.entries()));
    expect(Array.from(combined.positions.entries())).toEqual(Array.from(after.positions.entries()));
    expect(combined.placeholders).toEqual(after.placeholders);
  });

  it('uses independent headroom around a full-width gap barrier', () => {
    const assigned = new Map();
    const result = plan(['latest', 'gap:123', 'media:1:0'], assigned);

    expect(result.positions.get('gap:123')).toEqual({ top: 98, fullWidth: true });
    expect(result.positions.get('latest').top).toBe(0);
    expect(result.positions.get('media:1:0').top).toBe(146);
    expect(result.placeholders).toEqual([
      { key: 'gap:123:0', top: 146, column: 0, height: 88 },
      { key: 'gap:123:1', top: 146, column: 1, height: 88 },
      { key: 'leading:0', top: 0, column: 0, height: 98 },
      { key: 'leading:1', top: 0, column: 1, height: 98 },
    ]);
  });

  it('retains surviving assignments after deletion and reflows headroom without gaps', () => {
    const assigned = new Map();
    plan(['G', 'F', 'E', 'D'], assigned);
    assigned.delete('E');

    const after = plan(['G', 'F', 'D'], assigned);
    expect(['D', 'F', 'G'].map(key => assigned.get(key))).toEqual([2, 0, 1]);
    expect(after.height).toBe(188);
    expect(after.positions.get('D').top).toBe(0);
    expect(after.placeholders.map(blank => blank.height)).toEqual([40, 60]);
  });

  it('does not reassign an item after measurement changes', () => {
    const assigned = new Map();
    const first = planMasonryPrependFrontier(3, ['D'], assigned, () => 190);
    const snapshot = Array.from(assigned.entries());
    const measured = planMasonryPrependFrontier(3, ['D'], assigned, () => 330);

    expect(Array.from(assigned.entries())).toEqual(snapshot);
    expect(first.height).toBe(198);
    expect(measured.height).toBe(338);
    expect(measured.placeholders.map(blank => blank.height)).toEqual([338, 338]);
  });

  it('has no headroom placeholders for a single column', () => {
    const assigned = new Map();
    const single = planMasonryPrependFrontier(1, ['E', 'D'], assigned, height);

    expect(single.placeholders).toEqual([]);
    expect(single.positions.get('E').top).toBe(0);
    expect(single.height).toBe(296);
  });
});
