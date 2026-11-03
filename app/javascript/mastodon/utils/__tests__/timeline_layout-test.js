import { fromJS, List as ImmutableList } from 'immutable';

import {
  TIMELINE_LAYOUT_OPTIONS,
  normalizeTimelineLayout,
  isCardTimelineLayout,
  timelineCardColumnsForWidth,
  columnWidthForCardLayout,
  readTimelineLayout,
  mediaRowsForStatuses,
  statusHasTimelineMedia,
} from '../timeline_layout';

describe('timeline layout modes', () => {
  it('defines exactly the five available modes and defaults to normal', () => {
    expect(TIMELINE_LAYOUT_OPTIONS).toEqual(['normal', 'card-1', 'card-2', 'card-3', 'media']);
    expect(normalizeTimelineLayout(undefined)).toBe('normal');
    expect(normalizeTimelineLayout('masonry')).toBe('normal');
    expect(normalizeTimelineLayout('media')).toBe('media');
    expect(isCardTimelineLayout('card-3')).toBe(true);
    expect(isCardTimelineLayout('media')).toBe(false);
  });

  it('keeps a normal advanced desktop column to one card, but uses two on iPhone', () => {
    expect(timelineCardColumnsForWidth('card-1', 1000)).toBe(1);
    expect(timelineCardColumnsForWidth('card-2', 330)).toBe(1);
    expect(timelineCardColumnsForWidth('card-2', 375)).toBe(2);
    expect(timelineCardColumnsForWidth('card-3', 375)).toBe(2);
    expect(timelineCardColumnsForWidth('card-3', 540)).toBe(3);
    expect(timelineCardColumnsForWidth('card-3', 330)).toBe(1);
  });

  it.each([
    ['card-2', 'x080', 'x125'],
    ['card-2', 'x100', 'x125'],
    ['card-2', 'x125', 'x125'],
    ['card-2', 'x150', 'x150'],
    ['card-2', 'free', 'free'],
    ['card-3', 'x100', 'x200'],
    ['card-3', 'x125', 'x200'],
    ['card-3', 'x150', 'x200'],
    ['card-3', 'x200', 'x200'],
    ['card-3', 'free', 'free'],
    ['card-1', 'x100', 'x100'],
    ['media', 'x080', 'x080'],
    ['normal', 'x200', 'x200'],
    ['card-3', 'custom', 'custom'],
  ])('upgrades layout %s at width %s only when required', (mode, current, expected) => {
    expect(columnWidthForCardLayout(mode, current)).toBe(expected);
  });

  it('uses UUID-specific settings in pinned columns and type settings in standalone columns', () => {
    const state = fromJS({
      settings: {
        home: { layoutMode: 'card-3' },
        columns: [
          { uuid: 'one', params: { layoutMode: 'card-2' } },
          { uuid: 'two', params: {} },
          { uuid: 'three', params: { layoutMode: 'unrecognized' } },
        ],
      },
    });

    expect(readTimelineLayout(state, 'one', 'home')).toBe('card-2');
    expect(readTimelineLayout(state, 'two', 'home')).toBe('normal');
    expect(readTimelineLayout(state, 'three', 'home')).toBe('normal');
    expect(readTimelineLayout(state, 'missing', 'home')).toBe('normal');
    expect(readTimelineLayout(state, null, 'home')).toBe('card-3');
    expect(readTimelineLayout(state, null, null)).toBe('normal');
  });

  it('creates one tile per media attachment and skips text-only statuses', () => {
    const statuses = fromJS({
      '10': { media_attachments: [{ id: 'a', type: 'image' }, { id: 'b', type: 'video' }] },
      '20': { media_attachments: [] },
      '30': { reblog: '10', media_attachments: [] },
      '40': { media_attachments: [{ id: 'x' }, { id: 'x' }] },
    });
    const rows = mediaRowsForStatuses(ImmutableList(['10', '20', '30', null, '40']), statuses);

    expect(rows.map(row => row.kind)).toEqual(['media', 'media', 'media', 'media', 'gap', 'media', 'media']);
    expect(rows.filter(row => row.kind === 'media').map(row => row.id)).toEqual(['10', '10', '30', '30', '40', '40']);
    expect(rows.filter(row => row.kind === 'media').map(row => row.mediaIndex)).toEqual([0, 1, 0, 1, 0, 1]);
    expect(new Set(rows.filter(row => row.kind === 'media').map(row => row.key)).size).toBe(6);
    expect(rows.find(row => row.kind === 'gap')).toEqual({ kind: 'gap', position: 3 });
  });

  it('detects attachment-bearing posts and boosts consistently for split Live', () => {
    const statuses = fromJS({
      '10': { media_attachments: [{ id: 'image' }] },
      '20': { media_attachments: [] },
      '30': { reblog: '10', media_attachments: [] },
      '40': { media_attachments: [null] },
    });

    expect(statusHasTimelineMedia('10', statuses)).toBe(true);
    expect(statusHasTimelineMedia('20', statuses)).toBe(false);
    expect(statusHasTimelineMedia('30', statuses)).toBe(true);
    expect(statusHasTimelineMedia('40', statuses)).toBe(false);
    expect(statusHasTimelineMedia('missing', statuses)).toBe(false);
  });

  it('returns no tiles when all posts are without media', () => {
    const statuses = fromJS({ '10': { media_attachments: [] } });
    expect(mediaRowsForStatuses(ImmutableList(['10']), statuses)).toEqual([]);
    expect(mediaRowsForStatuses(ImmutableList(['99']), statuses)).toEqual([]);
  });
});
