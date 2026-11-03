import { isFullWidthMasonryKey, reconcileMasonryPrependRows } from '../timeline_masonry_layout';

const reconcile = (previous, next, rows = [], columns = 3) => (
  reconcileMasonryPrependRows(columns, previous, next, rows)
);

describe('streaming masonry prepend rows', () => {
  it('does not reserve rows on initial load or for one-column layouts', () => {
    expect(reconcile([], ['a', 'b'])).toEqual([]);
    expect(reconcile(['a', 'b'], ['c', 'a', 'b'], [], 1)).toEqual([]);
  });

  it('fills three columns end to start, then starts a new upper row', () => {
    let keys = ['a', 'b', 'c'];
    let rows = [];

    for (const nextId of ['d', 'e', 'f', 'g']) {
      const next = [nextId, ...keys];
      rows = reconcile(keys, next, rows);
      keys = next;
    }

    expect(rows).toEqual([
      { kind: 'slots', slots: [null, null, 'g'], nextColumn: 1 },
      { kind: 'slots', slots: ['f', 'e', 'd'], nextColumn: -1 },
    ]);
  });

  it('handles multiple statuses delivered at once in chronological order', () => {
    const rows = reconcile(['a', 'b'], ['e', 'd', 'c', 'a', 'b']);
    expect(rows).toEqual([
      { kind: 'slots', slots: ['e', 'd', 'c'], nextColumn: -1 },
    ]);
  });

  it('fills two-column masonry and does not treat older appended statuses as prepends', () => {
    const first = reconcile(['a'], ['b', 'a'], [], 2);
    expect(first[0].slots).toEqual([null, 'b']);
    const second = reconcile(['b', 'a'], ['c', 'b', 'a'], first, 2);
    expect(second[0].slots).toEqual(['c', 'b']);
    expect(reconcile(['c', 'b', 'a'], ['c', 'b', 'a', 'older'], second, 2)).toEqual(second);
  });

  it('retains empty slots when an already placed status is removed', () => {
    const filled = reconcile(['a'], ['d', 'c', 'b', 'a']);
    const removed = reconcile(['d', 'c', 'b', 'a'], ['d', 'b', 'a'], filled);
    expect(removed[0]).toEqual({
      kind: 'slots',
      slots: ['d', null, 'b'],
      nextColumn: -1,
    });
    const subsequent = reconcile(['d', 'b', 'a'], ['e', 'd', 'b', 'a'], removed);
    expect(subsequent[0].slots).toEqual([null, null, 'e']);
    expect(subsequent[1].slots).toEqual(['d', null, 'b']);
  });

  it('treats gaps and more rows as full-width barriers instead of column slots', () => {
    expect(isFullWidthMasonryKey('.$gap:123')).toBe(true);
    expect(isFullWidthMasonryKey('.$more:older')).toBe(true);
    expect(isFullWidthMasonryKey('.$media:123:0')).toBe(false);

    const rows = reconcile(['a'], ['latest', 'gap:123', 'media:12:0', 'a']);
    expect(rows).toEqual([
      { kind: 'slots', slots: [null, null, 'latest'], nextColumn: 1 },
      { kind: 'full', key: 'gap:123' },
      { kind: 'slots', slots: [null, null, 'media:12:0'], nextColumn: 1 },
    ]);
  });

  it('resets when the feed changes entirely or existing statuses reorder', () => {
    const rows = reconcile(['a'], ['b', 'a']);
    expect(reconcile(['b', 'a'], ['x', 'y'], rows)).toEqual([]);
    expect(reconcile(['b', 'a'], ['a', 'b'], rows)).toEqual([]);
  });
});
