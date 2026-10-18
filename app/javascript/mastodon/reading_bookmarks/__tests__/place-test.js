import {
  bookmarkColumnDecision,
  bookmarkLimitReached,
  bookmarkPresentation,
  bookmarksForScope,
  readingAnchorFromSurface,
  readingBookmarkFailure,
  sameReadingPlace,
} from '../place';

const anchor = {
  version: 1,
  statusId: '80',
  displayRowId: '80',
  offsetPx: 12,
  alignment: 'top',
};

const home = {
  source: 'home',
  path: '/api/v1/timelines/home',
  params: { visibilities: [] },
};

const bookmark = (overrides = {}) => ({
  id: '4',
  name: 'Morning',
  source: 'home',
  sourceTimelineId: 'home',
  context: {},
  anchor,
  sourceLabel: null,
  availability: { source: 'available', anchor: 'visible', membership: 'unchecked' },
  lockVersion: 0,
  updatedAt: '2026-10-18T01:00:00Z',
  ...overrides,
});

describe('reading bookmark place', () => {
  it('saves only a history surface anchor and refuses an empty or live-sized stand-in', () => {
    expect(readingAnchorFromSurface(null)).toEqual({ ok: false, reason: 'history_closed' });
    expect(readingAnchorFromSurface({
      version: 1,
      statusId: null,
      displayRowId: null,
      offsetPx: 0,
      alignment: 'top',
    }).reason).toBe('no_reading_anchor');
    expect(readingAnchorFromSurface({
      ...anchor,
      window: ['80'],
    }).reason).toBe('window_not_accepted');
    expect(readingAnchorFromSurface({
      ...anchor,
      q: 'hidden-query-zz',
    }).reason).toBe('search_or_content_not_accepted');

    const captured = readingAnchorFromSurface({
      ...anchor,
      displayRowId: 'f-80',
      capturedAt: '2026-10-18T01:00:00Z',
    });

    expect(captured.ok).toBe(true);
    expect(captured.anchor.displayRowId).toBe('f-80');
    expect(captured.anchor.statusId).toBe('80');
  });

  it('matches source and context, including flags the timeline id omits', () => {
    expect(sameReadingPlace(bookmark(), home)).toBe(true);
    expect(sameReadingPlace(bookmark({
      context: { visibilities: ['public'] },
    }), {
      source: 'home',
      path: '/api/v1/timelines/home',
      params: { visibilities: ['public'] },
    })).toBe(true);
    expect(sameReadingPlace(bookmark(), {
      source: 'home',
      path: '/api/v1/timelines/home',
      params: { visibilities: ['private'] },
    })).toBe(false);

    const localPublic = {
      source: 'public',
      path: '/api/v1/timelines/public',
      params: { remote: false, only_media: false, without_media: false, without_bot: false },
    };
    const remotePublic = {
      ...localPublic,
      params: { ...localPublic.params, remote: true },
    };
    const row = bookmark({
      source: 'public',
      sourceTimelineId: 'public',
      context: localPublic.params,
    });

    expect(sameReadingPlace(row, localPublic)).toBe(true);
    expect(sameReadingPlace(row, remotePublic)).toBe(false);
    expect(sameReadingPlace(bookmark({
      source: 'list',
      sourceTimelineId: 'list:42',
      context: { id: '42' },
    }), {
      source: 'list',
      path: '/api/v1/timelines/list/9',
      params: {},
    })).toBe(false);
  });

  it('does not treat a saved membership flag as permission to move', () => {
    const unchecked = bookmarkColumnDecision(bookmark(), home);
    const claimed = bookmarkColumnDecision(bookmark({
      availability: { source: 'available', anchor: 'visible', membership: 'member' },
    }), home);

    expect(unchecked).toEqual({ action: 'recheck', place: 'pending', reason: 'membership_unchecked' });
    expect(claimed.action).toBe('recheck');
    expect(bookmarkColumnDecision(bookmark({
      source: 'list',
      sourceTimelineId: 'list:4',
      context: { id: '4' },
    }), home).action).toBe('guide');
    expect(bookmarkColumnDecision(bookmark({
      availability: { source: 'missing', membership: 'unchecked' },
      sourceLabel: 'Secret list',
    }), home)).toEqual({ action: 'refuse', place: 'unavailable', reason: 'missing' });
    expect(bookmarkColumnDecision(bookmark({
      availability: { source: 'uncertain' },
    }), home).place).toBe('uncertain');
  });

  it('hides names of missing timelines and keeps bodies out of the presentation', () => {
    const hidden = bookmarkPresentation(bookmark({
      source: 'list',
      sourceLabel: 'Secret list',
      availability: { source: 'missing', anchor: 'unchecked' },
      text: 'private body',
    }));

    expect(hidden.sourceLabel).toBeNull();
    expect(hidden.membership).toBe('unchecked');
    expect(JSON.stringify(hidden)).not.toContain('Secret list');
    expect(JSON.stringify(hidden)).not.toContain('private body');
    expect(bookmarksForScope([
      bookmark(),
      bookmark({ id: '9', source: 'list', sourceTimelineId: 'list:9', context: { id: '9' } }),
    ], home, 'column')).toHaveLength(1);
    expect(bookmarkLimitReached(Array.from({ length: 50 }, (_, index) => bookmark({ id: String(index + 1) })))).toBe(true);
  });

  it('maps 409, the 50 cap, and duplicate names without keeping a response body', () => {
    expect(readingBookmarkFailure({ response: { status: 409, data: { error: 'conflict', text: 'secret-body' } } })).toEqual({
      ok: false,
      reason: 'conflict',
      status: 409,
    });
    expect(readingBookmarkFailure({ response: { status: 422, data: { error: 'limit' } } }).reason).toBe('limit');
    expect(readingBookmarkFailure({ response: { status: 422, data: { error: 'duplicate_name' } } }).reason).toBe('duplicate_name');
    expect(readingBookmarkFailure({ response: { status: 500, data: { error: 'secret-body' } } })).toEqual({
      ok: false,
      reason: 'network',
      status: 500,
    });
    expect(JSON.stringify(readingBookmarkFailure({
      response: { status: 422, data: { error: 'duplicate_name', text: 'secret-body' } },
    }))).not.toContain('secret-body');
  });
});
