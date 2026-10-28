jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import { TIMELINE_DELETE, TIMELINE_EXPAND_SUCCESS, TIMELINE_EXTERNAL_RECONCILE, TIMELINE_LOAD_PENDING, TIMELINE_UPDATE } from '../../actions/timelines';
import { MIX_EXTERNAL_RECONCILE, MIX_STREAM_STATUS } from '../../actions/mix_timelines';
import timelines from '../../reducers/timelines';
import mixTimelines from '../../reducers/mix_timelines';
import { exhaustedTailSegment, insertIdDescending, nextExhaustedPage } from '../reconcile';

const timeline = (overrides = {}) => ImmutableMap({
  unread: 0,
  online: false,
  top: true,
  isLoading: false,
  hasMore: true,
  pendingItems: ImmutableList(),
  items: ImmutableList(),
  ...overrides,
});

const arrive = (state, timelineId, id, extra = {}) => timelines(state, {
  type: TIMELINE_UPDATE,
  timeline: timelineId,
  status: { id, visibility_ex: 'external', visibility: 'direct', ...extra },
  usePendingItems: false,
});

describe('external late arrivals', () => {
  it('places 11:00, 09:00, then 10:00 as 11:00, 10:00, 09:00 without using Number', () => {
    let state = ImmutableMap({
      home: timeline({ items: ImmutableList(), hasMore: false }),
    });

    state = arrive(state, 'home', '9007199254741100');
    state = arrive(state, 'home', '9007199254740900');
    state = arrive(state, 'home', '9007199254741000');

    expect(state.getIn(['home', 'items']).toArray()).toEqual([
      '9007199254741100',
      '9007199254741000',
      '9007199254740900',
    ]);
    expect(state.getIn(['home', 'unread'])).toBe(0);
  });

  it('keeps a normal status prepended and does not close a null gap', () => {
    const state = ImmutableMap({
      home: timeline({
        items: ImmutableList(['300', null, '100']),
        top: false,
        unread: 2,
      }),
    });
    const late = arrive(state, 'home', '200');
    const ordinary = timelines(state, {
      type: TIMELINE_UPDATE,
      timeline: 'home',
      status: { id: '400', visibility: 'public' },
      usePendingItems: false,
    });

    expect(late.getIn(['home', 'items']).toArray()).toEqual(['300', null, '100']);
    expect(late.getIn(['home', 'pendingItems']).toArray()).toEqual([]);
    expect(late.getIn(['home', 'unread'])).toBe(2);
    expect(ordinary.getIn(['home', 'items']).toArray()).toEqual(['400', '300', null, '100']);
    expect(ordinary.getIn(['home', 'pendingItems']).toArray()).toEqual([]);
    expect(ordinary.getIn(['home', 'unread'])).toBe(3);
  });

  it('sorts a late id into pending and expands pending without moving it above newer rows', () => {
    let state = ImmutableMap({
      home: timeline({
        items: ImmutableList(['300', '100']),
        pendingItems: ImmutableList(['500']),
        top: false,
        unread: 1,
      }),
      'list:4': timeline({
        items: ImmutableList(['300', '100']),
        top: true,
      }),
    });

    state = arrive(state, 'home', '400');
    state = arrive(state, 'list:4', '200');

    expect(state.getIn(['home', 'pendingItems']).toArray()).toEqual(['500', '400']);
    expect(state.getIn(['home', 'items']).toArray()).toEqual(['300', '100']);
    expect(state.getIn(['home', 'unread'])).toBe(2);
    expect(state.getIn(['list:4', 'items']).toArray()).toEqual(['300', '200', '100']);

    const loaded = timelines(state, { type: TIMELINE_LOAD_PENDING, timeline: 'home' });

    expect(loaded.getIn(['home', 'items']).toArray().slice(0, 4)).toEqual(['500', '400', '300', '100']);
    expect(loaded.getIn(['home', 'pendingItems']).toArray()).toEqual([]);
    expect(insertIdDescending(['500', '300'], '400')).toEqual(['500', '400', '300']);
  });

  it('inserts into the live list and the split history without closing the gap between them', () => {
    const splitId = 'home:split:X';
    const state = ImmutableMap({
      home: timeline({
        items: ImmutableList(['500', '300']),
        splitTimelineId: splitId,
        top: false,
      }),
      [splitId]: timeline({
        items: ImmutableList(['300', null, '100']),
        top: false,
      }),
    });
    const insideHistoryGap = arrive(state, 'home', '200');
    const insideLive = arrive(state, 'home', '400');
    const insideHistory = arrive(ImmutableMap({
      home: timeline({
        items: ImmutableList(['500', '300']),
        splitTimelineId: splitId,
      }),
      [splitId]: timeline({
        items: ImmutableList(['300', '100']),
      }),
    }), 'home', '200');

    expect(insideHistoryGap.getIn([splitId, 'items']).toArray()).toEqual(['300', null, '100']);
    expect(insideHistoryGap.getIn(['home', 'items']).toArray()).toEqual(['500', '300']);
    expect(insideLive.getIn(['home', 'items']).toArray()).toEqual(['500', '400', '300']);
    expect(insideLive.getIn([splitId, 'items']).toArray()).toEqual(['300', null, '100']);
    expect(insideHistory.getIn([splitId, 'items']).toArray()).toEqual(['300', '200', '100']);
    expect(insideHistory.getIn(['home', 'items']).toArray()).toEqual(['500', '300']);
    expect(insideHistory.getIn(['home', 'unread'])).toBe(0);
  });

  it('places a late mix id inside the loaded source and leaves a newer id pending', () => {
    let state = mixTimelines(undefined, {
      type: 'MIX_TIMELINE_OPEN',
      columnKey: 'column:a',
      mixId: 'mix-1',
      definitionFingerprint: 'home',
      sessionId: 1,
      sources: [
        { key: 'home', descriptor: { type: 'home', params: {} } },
      ],
    });
    state = mixTimelines(state, {
      type: 'MIX_SOURCE_SUCCESS',
      columnKey: 'column:a',
      sourceKey: 'home',
      sessionId: 1,
      definitionFingerprint: 'home',
      ids: ['500', '300', '100'],
      cursor: '100',
      frontier: '100',
      hasMore: true,
      partial: false,
    });
    state = state.setIn(['column:a', 'pinnedToTop'], false);

    const late = mixTimelines(state, {
      type: MIX_STREAM_STATUS,
      columnKey: 'column:a',
      sourceKey: 'home',
      sessionId: 1,
      definitionFingerprint: 'home',
      id: '400',
      decision: 'accept',
      external: true,
      filterResults: [],
    });
    const older = mixTimelines(state, {
      type: MIX_STREAM_STATUS,
      columnKey: 'column:a',
      sourceKey: 'home',
      sessionId: 1,
      definitionFingerprint: 'home',
      id: '50',
      decision: 'accept',
      external: true,
      filterResults: [],
    });
    const newer = mixTimelines(late, {
      type: MIX_STREAM_STATUS,
      columnKey: 'column:a',
      sourceKey: 'home',
      sessionId: 1,
      definitionFingerprint: 'home',
      id: '600',
      decision: 'accept',
      external: true,
      filterResults: [],
    });

    expect(late.getIn(['column:a', 'sources', 'home', 'ids']).toArray()).toEqual(['500', '400', '300', '100']);
    expect(late.getIn(['column:a', 'pendingStatusIds']).toArray()).toEqual([]);
    expect(older.getIn(['column:a', 'sources', 'home', 'ids']).toArray()).toEqual(['500', '300', '100']);
    expect(older.getIn(['column:a', 'live', 'home', 'statusIds'])).toBeUndefined();
    expect(newer.getIn(['column:a', 'pendingStatusIds']).toArray()).toEqual(['600']);
  });

  it('does not advance an open tail when deletions leave one loaded id', () => {
    const loaded = Array.from({ length: 20 }, (_value, index) => String(500 - index));
    let state = ImmutableMap({
      home: timeline({ hasMore: true }),
    });

    state = timelines(state, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: 'home',
      statuses: loaded.map(id => ({ id })),
      next: '/api/v1/timelines/home?max_id=481',
      partial: false,
      isLoadingRecent: false,
      isLoadingMore: false,
      usePendingItems: false,
    });
    loaded.slice(1).forEach(id => {
      state = timelines(state, { type: TIMELINE_DELETE, id, references: [] });
    });
    state = arrive(state, 'home', '100');

    expect(state.getIn(['home', 'hasMore'])).toBe(true);
    expect(state.getIn(['home', 'items']).toArray()).toEqual(['500']);

    const olderPage = Array.from({ length: 20 }, (_value, index) => String(480 - index));

    state = timelines(state, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: 'home',
      statuses: olderPage.map(id => ({ id })),
      next: '/api/v1/timelines/home?max_id=461',
      partial: false,
      isLoadingRecent: false,
      isLoadingMore: true,
      usePendingItems: false,
    });

    const items = state.getIn(['home', 'items']).toArray();

    expect(items[0]).toBe('500');
    expect(items).toContain('480');
    expect(items).toContain('461');
    expect(items).not.toContain('100');
    expect(items[items.length - 1]).toBe('461');
  });

  it('appends an older external id only after the older page is confirmed empty', () => {
    let state = ImmutableMap({
      home: timeline({
        items: ImmutableList(['500', '300']),
        hasMore: true,
      }),
    });

    state = timelines(state, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: 'home',
      statuses: [],
      next: null,
      partial: false,
      isLoadingRecent: false,
      isLoadingMore: true,
      usePendingItems: false,
    });
    expect(state.getIn(['home', 'hasMore'])).toBe(false);
    expect(state.getIn(['home', 'items']).toArray()).toEqual(['500', '300']);

    const open = ImmutableMap({
      home: timeline({ items: ImmutableList(['500', '300']), hasMore: true }),
    });

    expect(arrive(open, 'home', '200').getIn(['home', 'items']).toArray()).toEqual(['500', '300']);
    state = arrive(state, 'home', '200');
    state = arrive(state, 'home', '200');
    expect(state.getIn(['home', 'items']).toArray()).toEqual(['500', '300', '200']);

    const missed = timelines(ImmutableMap({
      home: timeline({ items: ImmutableList(['500', '300']), hasMore: false }),
    }), {
      type: TIMELINE_EXTERNAL_RECONCILE,
      timeline: 'home',
      removeIds: [],
      insertIds: ['200', '200'],
    });
    const stillOpen = timelines(open, {
      type: TIMELINE_EXTERNAL_RECONCILE,
      timeline: 'home',
      removeIds: [],
      insertIds: ['200'],
    });

    expect(missed.getIn(['home', 'items']).toArray()).toEqual(['500', '300', '200']);
    expect(missed.getIn(['home', 'hasMore'])).toBe(false);
    expect(stillOpen.getIn(['home', 'items']).toArray()).toEqual(['500', '300']);
    expect(exhaustedTailSegment(['500', '300']).oldest).toBe('300');
    expect(exhaustedTailSegment(['500', null])).toBeNull();
    expect(nextExhaustedPage([{ id: '200' }, { id: '100' }], 2)).toEqual({ done: false, cursor: '100' });
    expect(nextExhaustedPage([{ id: '200' }], 2)).toEqual({ done: true, cursor: null });
  });

  it('does not extend a mix tail that still has older pages', () => {
    const open = (hasMore) => {
      let state = mixTimelines(undefined, {
        type: 'MIX_TIMELINE_OPEN',
        columnKey: 'column:a',
        mixId: 'mix-1',
        definitionFingerprint: 'home',
        sessionId: 1,
        sources: [
          { key: 'home', descriptor: { type: 'home', params: {} } },
        ],
      });

      state = mixTimelines(state, {
        type: 'MIX_SOURCE_SUCCESS',
        columnKey: 'column:a',
        sourceKey: 'home',
        sessionId: 1,
        definitionFingerprint: 'home',
        ids: ['500'],
        cursor: '500',
        frontier: '500',
        hasMore,
        partial: false,
      });

      return mixTimelines(state, {
        type: MIX_STREAM_STATUS,
        columnKey: 'column:a',
        sourceKey: 'home',
        sessionId: 1,
        definitionFingerprint: 'home',
        id: '100',
        decision: 'accept',
        external: true,
        filterResults: [],
      });
    };

    expect(open(true).getIn(['column:a', 'sources', 'home', 'ids']).toArray()).toEqual(['500']);

    const closed = open(false);

    expect(closed.getIn(['column:a', 'sources', 'home', 'ids']).toArray()).toEqual(['500', '100']);

    const resynced = mixTimelines(closed.setIn(['column:a', 'sources', 'home', 'ids'], ImmutableList(['500', '300'])), {
      type: MIX_EXTERNAL_RECONCILE,
      columnKey: 'column:a',
      sourceKey: 'home',
      sessionId: 1,
      definitionFingerprint: 'home',
      removeIds: [],
      insertIds: ['200'],
      range: { side: 'live' },
    });

    expect(resynced.getIn(['column:a', 'sources', 'home', 'ids']).toArray()).toEqual(['500', '300', '200']);
  });
});
