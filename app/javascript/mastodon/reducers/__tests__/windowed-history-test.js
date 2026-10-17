import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import {
  TIMELINE_DELETE,
  TIMELINE_EXPAND_SUCCESS,
  TIMELINE_SPLIT_CREATE,
  TIMELINE_SPLIT_DESTROY,
  TIMELINE_SPLIT_KEEP_LIVE,
  TIMELINE_UPDATE,
} from '../../actions/timelines';
import { WINDOW_HISTORY_FAIL, WINDOW_HISTORY_REQUEST, WINDOW_HISTORY_SUCCESS } from '../../windowed_history/types';
import timelines from '../timelines';

const splitId = 'home:split:session';
const snowflake = '9007199254740993';

const sourceItems = (count, anchorAt) => {
  const ids = Array.from({ length: count }, (_, index) => String(5000 - index).padStart(6, '0'));

  return { ids: ImmutableList(ids), anchorId: ids[anchorAt] };
};

const withHome = (items, extra = {}) => ImmutableMap({
  home: ImmutableMap({
    unread: 2,
    online: true,
    top: false,
    isLoading: false,
    hasMore: true,
    pendingItems: ImmutableList(['0005100', '0005050']),
    items,
    ...extra,
  }),
});

const create = (state, anchorId) => timelines(state, {
  type: TIMELINE_SPLIT_CREATE,
  sourceTimeline: 'home',
  splitTimeline: splitId,
  anchorId,
});

describe('windowed history reducer', () => {
  it('windows around the anchor and leaves canonical home and live pending untouched', () => {
    const { ids, anchorId } = sourceItems(400, 250);
    const next = create(withHome(ids), anchorId);
    const history = next.getIn([splitId, 'items']);

    expect(next.getIn(['home', 'items'])).toEqual(ids);
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['0005100', '0005050']));
    expect(history).toContain(anchorId);
    expect(history.first()).not.toBe(ids.first());
    expect(history.size).toBeLessThanOrEqual(240);
    expect(next.getIn([splitId, 'window', 'hasNewer'])).toBe(true);
    expect(next.getIn([splitId, 'window', 'hasOlder'])).toBe(true);
    expect(next.getIn([splitId, 'splitBoundaryId'])).toBe(ids.first());
  });

  it('keeps a partial gap out of the cursors', () => {
    const items = ImmutableList(['300', '200', null, '100']);
    const next = create(withHome(items), '200');

    expect(next.getIn([splitId, 'items'])).toEqual(items);
    expect(next.getIn([splitId, 'window', 'newestId'])).toBe('300');
    expect(next.getIn([splitId, 'window', 'oldestId'])).toBe('100');
  });

  it('drops a stale page after the split is gone and keeps home intact', () => {
    const { ids, anchorId } = sourceItems(10, 4);
    const split = create(withHome(ids), anchorId);
    const closed = timelines(split, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop: false,
    });
    const stale = timelines(closed, {
      type: WINDOW_HISTORY_SUCCESS,
      timeline: splitId,
      direction: 'older',
      requestId: 'req-1',
      generation: 1,
      statuses: [{ id: '1' }],
      cursor: ids.last(),
      limit: 20,
      capability: 'database',
    });

    expect(stale.get(splitId)).toBeUndefined();
    expect(stale.getIn(['home', 'items'])).toEqual(ImmutableList(['0005100', '0005050']).concat(ids));
    expect(stale.getIn(['home', 'pendingItems'])).toEqual(ImmutableList());
  });

  it('does not let an older response replace a newer in-flight request', () => {
    const items = ImmutableList(['30', '20', '10']);
    const split = create(withHome(items, { pendingItems: ImmutableList() }), '20');
    const requested = timelines(split, {
      type: WINDOW_HISTORY_REQUEST,
      timeline: splitId,
      direction: 'older',
      cursor: '10',
      requestId: 'req-a',
      generation: 1,
    });
    const replaced = timelines(requested, {
      type: WINDOW_HISTORY_REQUEST,
      timeline: splitId,
      direction: 'older',
      cursor: '20',
      requestId: 'req-b',
      generation: 1,
    });
    const stale = timelines(replaced, {
      type: WINDOW_HISTORY_SUCCESS,
      timeline: splitId,
      direction: 'older',
      requestId: 'req-a',
      generation: 1,
      statuses: [{ id: '9' }],
      cursor: '10',
      limit: 20,
      capability: 'redis',
    });

    expect(stale.getIn([splitId, 'items'])).toEqual(items);
    expect(stale.getIn([splitId, 'window', 'older', 'requestId'])).toBe('req-b');
    expect(stale.getIn([splitId, 'window', 'older', 'status'])).toBe('loading');
    expect(stale.getIn([splitId, 'isLoading'])).toBe(true);
  });

  it('refuses the opposite page while one direction is loading and keeps canonical items', () => {
    const { ids, anchorId } = sourceItems(400, 250);
    let state = create(withHome(ids, { pendingItems: ImmutableList(['0005100']) }), anchorId);
    const newestId = state.getIn([splitId, 'window', 'newestId']);
    const oldestId = state.getIn([splitId, 'window', 'oldestId']);

    state = timelines(state, {
      type: TIMELINE_UPDATE,
      timeline: 'home',
      status: { id: '0005200' },
      usePendingItems: true,
    });
    state = timelines(state, {
      type: WINDOW_HISTORY_REQUEST,
      timeline: splitId,
      direction: 'older',
      cursor: oldestId,
      requestId: 'req-a',
      generation: 1,
    });
    state = timelines(state, {
      type: WINDOW_HISTORY_REQUEST,
      timeline: splitId,
      direction: 'newer',
      cursor: newestId,
      requestId: 'req-b',
      generation: 1,
    });
    state = timelines(state, {
      type: WINDOW_HISTORY_FAIL,
      timeline: splitId,
      direction: 'older',
      requestId: 'req-a',
      generation: 1,
    });

    expect(state.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['0005200', '0005100']));
    expect(state.getIn(['home', 'items'])).toEqual(ids);
    expect(state.getIn([splitId, 'window', 'older', 'status'])).toBe('error');
    expect(state.getIn([splitId, 'window', 'newer', 'status'])).not.toBe('loading');
    expect(state.getIn([splitId, 'window', 'newer', 'requestId'])).toBeNull();
    expect(state.getIn([splitId, 'hasMore'])).toBe(false);
    expect(state.getIn([splitId, 'window', 'hasOlder'])).toBe(true);
  });

  it('merges trimmed history into canonical items on keep-history and drops it on keep-live', () => {
    const canonical = ImmutableList(['500', '400', '300', '200', '100']);
    const history = ImmutableList(['300', '200', '150']);
    const base = withHome(canonical, {
      pendingItems: ImmutableList(['600']),
      splitTimelineId: splitId,
      hasMore: true,
    }).set(splitId, ImmutableMap({
      unread: 0,
      online: false,
      top: false,
      isLoading: false,
      hasMore: true,
      pendingItems: ImmutableList(),
      items: history,
      splitBoundaryId: '500',
      window: ImmutableMap({
        generation: 1,
        anchorId: '200',
        anchorResolution: 'exact',
        unbounded: false,
        boundaryId: '500',
        newestId: '300',
        oldestId: '150',
        hasNewer: true,
        hasOlder: true,
        newer: ImmutableMap({ status: 'open', requestId: null, cursor: '300' }),
        older: ImmutableMap({ status: 'open', requestId: null, cursor: '150' }),
      }),
    }));

    const kept = timelines(base, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
    });

    expect(kept.getIn(['home', 'items'])).toEqual(ImmutableList(['500', '400', '300', '200', '150', '100']));
    expect(kept.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['600']));
    expect(kept.getIn(['home', 'hasMore'])).toBe(true);
    expect(kept.get(splitId)).toBeUndefined();

    const live = timelines(base, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop: true,
    });

    expect(live.getIn(['home', 'items'])).toEqual(ImmutableList(['600', '500', '400', '300', '200', '100']));
    expect(live.getIn(['home', 'items'])).not.toContain('150');
    expect(live.get(splitId)).toBeUndefined();
  });

  it('keeps a deleted status out of both panes and repairs the history cursor', () => {
    const items = ImmutableList(['300', snowflake, '100']);
    const split = create(withHome(items, { pendingItems: ImmutableList() }), snowflake);
    const next = timelines(split, {
      type: TIMELINE_DELETE,
      id: snowflake,
      references: [],
    });

    expect(next.getIn(['home', 'items']).includes(snowflake)).toBe(false);
    expect(next.getIn([splitId, 'items']).includes(snowflake)).toBe(false);
    expect(typeof next.getIn([splitId, 'window', 'anchorId'])).toBe('string');
    expect(next.getIn([splitId, 'window', 'anchorId'])).not.toBe(snowflake);
  });

  it('still appends an older expand page without growing past the cap', () => {
    const { ids, anchorId } = sourceItems(240, 20);
    const split = create(withHome(ids), anchorId);
    const next = timelines(split, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: splitId,
      statuses: [{ id: '004000' }, { id: '003999' }],
      next: '/next',
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });
    const history = next.getIn([splitId, 'items']);

    expect(history.includes('004000')).toBe(true);
    expect(history.size).toBeLessThanOrEqual(320);
    expect(next.getIn(['home', 'items'])).toEqual(ids);
  });
});
