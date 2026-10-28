jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import { TIMELINE_LOAD_PENDING, TIMELINE_UPDATE } from '../../actions/timelines';
import { MIX_STREAM_STATUS } from '../../actions/mix_timelines';
import timelines from '../../reducers/timelines';
import mixTimelines from '../../reducers/mix_timelines';
import { insertIdDescending } from '../reconcile';

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
      home: timeline({ items: ImmutableList() }),
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
});
