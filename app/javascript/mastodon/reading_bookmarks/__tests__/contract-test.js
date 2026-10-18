import {
  normalizeReadingBookmark,
  readingBookmarkPayload,
  readingBookmarkPayloadFromPosition,
} from '../contract';

const anchor = {
  version: 1,
  statusId: '109717037387162260',
  displayRowId: '109717037387162260',
  offsetPx: 12,
  alignment: 'top',
  capturedAt: '2026-10-18T00:00:00Z',
};

describe('reading bookmark contract', () => {
  it('builds a source and anchor without a column, window, or search term', () => {
    const built = readingBookmarkPayload({
      name: '  Morning  ',
      contract: {
        source: 'list',
        path: '/api/v1/timelines/list/42',
        params: {},
      },
      anchor,
      sourceTimelineId: 'list:42',
    });

    expect(built.ok).toBe(true);
    expect(built.payload).toEqual({
      name: 'Morning',
      source: 'list',
      source_timeline_id: 'list:42',
      context: { id: '42' },
      anchor: {
        version: 1,
        status_id: anchor.statusId,
        display_row_id: anchor.displayRowId,
        offset_px: 12,
        alignment: 'top',
        captured_at: anchor.capturedAt,
      },
    });
    expect(JSON.stringify(built.payload)).not.toContain('column');
  });

  it('drops the P3 view and does not keep a smuggled status body', () => {
    const built = readingBookmarkPayloadFromPosition({
      name: 'Place',
      position: {
        version: 1,
        source: {
          kind: 'timeline_source',
          sourceTimelineId: 'home',
          conditions: { visibilities: ['public'] },
        },
        view: {
          kind: 'timeline_view',
          columnId: 'column-secret',
          scrollKey: 'home:history:column-secret',
          pane: 'history',
        },
        anchor,
      },
    });

    expect(built.ok).toBe(true);
    expect(built.payload.source).toBe('home');
    expect(built.payload.context).toEqual({ visibilities: ['public'] });
    expect(built.payload.view).toBeUndefined();
    expect(JSON.stringify(built.payload)).not.toContain('column-secret');
  });

  it('refuses search text instead of saving a timeline without it', () => {
    const built = readingBookmarkPayload({
      name: 'Find',
      contract: {
        source: 'home',
        params: { q: 'hidden-query-zz', visibilities: ['public'] },
      },
      anchor,
    });

    expect(built.ok).toBe(false);
    expect(built.reason).toBe('search_or_content_not_accepted');
    expect(JSON.stringify(built)).not.toContain('hidden-query-zz');
  });

  it('refuses a window and a fractional pixel offset', () => {
    expect(readingBookmarkPayload({
      name: 'Window',
      contract: { source: 'public', params: { statuses: ['1'] } },
      anchor,
    }).reason).toBe('window_not_accepted');

    expect(readingBookmarkPayload({
      name: 'Offset',
      contract: { source: 'public', params: {} },
      anchor: { ...anchor, offsetPx: 1.5 },
    }).reason).toBe('invalid_anchor');
  });

  it('refuses a source id that disagrees with the path', () => {
    const built = readingBookmarkPayloadFromPosition({
      name: 'Wrong list',
      position: {
        version: 1,
        source: {
          kind: 'timeline_source',
          sourceTimelineId: 'list:9',
          conditions: { id: '4' },
        },
        anchor,
      },
    });

    expect(built.reason).toBe('source_mismatch');
  });

  it('normalizes a server row without copying status text', () => {
    const row = normalizeReadingBookmark({
      id: 7,
      name: 'Place',
      source: 'home',
      source_timeline_id: 'home',
      context: {},
      anchor: { version: 1, status_id: '15', offset_px: 0, alignment: 'top' },
      source_label: null,
      availability: { source: 'available', anchor: 'visible', resume: 'manual' },
      lock_version: 0,
      text: 'secret-status-body',
      window: [{ id: '15' }],
    });

    expect(row.id).toBe('7');
    expect(row.anchor.statusId).toBe('15');
    expect(row.text).toBeUndefined();
    expect(row.window).toBeUndefined();
    expect(JSON.stringify(row)).not.toContain('secret-status-body');
  });
});
