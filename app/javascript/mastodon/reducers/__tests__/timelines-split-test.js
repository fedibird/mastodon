import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';

import { ACCOUNT_UNFOLLOW_SUCCESS, ACCOUNT_UNSUBSCRIBE_SUCCESS } from '../../actions/accounts';
import {
  TIMELINE_DELETE,
  TIMELINE_EXPAND_SUCCESS,
  TIMELINE_MARK_AS_PARTIAL,
  TIMELINE_SCROLL_TOP,
  TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR,
  TIMELINE_SPLIT_CREATE,
  TIMELINE_SPLIT_DESTROY,
  TIMELINE_SPLIT_KEEP_LIVE,
  TIMELINE_SPLIT_SAVE_RETURN_ANCHOR,
  TIMELINE_UPDATE,
} from '../../actions/timelines';
import timelines from '../timelines';

const splitId = 'home:split:X';

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

const withHome = (homeOverrides, extra = {}) => ImmutableMap({
  home: timeline(homeOverrides),
  ...extra,
});

const createSplit = (state) => timelines(state, {
  type: TIMELINE_SPLIT_CREATE,
  sourceTimeline: 'home',
  splitTimeline: splitId,
});

const destroySplit = (state) => timelines(state, {
  type: TIMELINE_SPLIT_DESTROY,
  sourceTimeline: 'home',
  splitTimeline: splitId,
});

describe('timeline split lifecycle', () => {
  const initial = () => withHome({
    items: ImmutableList(['100', '90', '80']),
    pendingItems: ImmutableList(['110', '105']),
    online: true,
    unread: 2,
    top: false,
    hasMore: false,
    isPartial: false,
  });

  it('snapshots the current home history without rewriting canonical home', () => {
    const next = createSplit(initial());

    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['110', '105']));
    expect(next.getIn(['home', 'splitTimelineId'])).toBe(splitId);
    expect(next.getIn(['home', 'online'])).toBe(true);

    expect(next.getIn([splitId, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn([splitId, 'pendingItems'])).toEqual(ImmutableList());
    expect(next.getIn([splitId, 'splitBoundaryId'])).toBe('100');
    expect(next.getIn([splitId, 'online'])).toBe(false);
    expect(next.getIn([splitId, 'unread'])).toBe(0);
    expect(next.getIn([splitId, 'isLoading'])).toBe(false);
    expect(next.getIn([splitId, 'hasMore'])).toBe(false);
    expect(next.getIn([splitId, 'isPartial'])).toBe(false);
    expect(next.getIn([splitId, 'top'])).toBe(false);
  });

  it('does not create a second split while one is active', () => {
    const split = createSplit(initial());
    const again = timelines(split, {
      type: TIMELINE_SPLIT_CREATE,
      sourceTimeline: 'home',
      splitTimeline: 'home:split:Y',
    });

    expect(again).toBe(split);
  });

  it('keeps streaming updates on canonical home', () => {
    const split = createSplit(initial());
    const next = timelines(split, {
      type: TIMELINE_UPDATE,
      timeline: 'home',
      status: { id: '120' },
      usePendingItems: true,
    });

    expect(next.getIn(['home', 'pendingItems']).first()).toBe('120');
    expect(next.getIn([splitId, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn([splitId, 'pendingItems'])).toEqual(ImmutableList());
  });

  it('queues updates as pending during a split when pending items are disabled and the timeline is at the top', () => {
    const items = ImmutableList(Array.from({ length: 41 }, (_, index) => String(1000 - index).padStart(4, '0')));
    const split = createSplit(withHome({
      items,
      pendingItems: ImmutableList(),
      top: true,
      unread: 0,
    }));

    let next = split;

    ['2002', '2001', '2000'].forEach(id => {
      next = timelines(next, {
        type: TIMELINE_UPDATE,
        timeline: 'home',
        status: { id },
        usePendingItems: false,
      });
    });

    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['2000', '2001', '2002']));
    expect(next.getIn(['home', 'items'])).toEqual(items);
    expect(next.getIn(['home', 'unread'])).toBe(3);
    expect(next.getIn([splitId, 'items'])).toEqual(items);
    expect(next.getIn([splitId, 'pendingItems'])).toEqual(ImmutableList());
  });

  it('appends older history only to the split timeline', () => {
    const split = createSplit(initial());
    const next = timelines(split, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: splitId,
      statuses: [{ id: '70' }, { id: '60' }],
      next: '/next',
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });

    expect(next.getIn([splitId, 'items'])).toEqual(ImmutableList(['100', '90', '80', '70', '60']));
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
  });

  it('deletes a status from both the live and history timelines', () => {
    const split = createSplit(initial());
    const next = timelines(split, {
      type: TIMELINE_DELETE,
      id: '100',
      references: [],
    });

    expect(next.getIn(['home', 'items']).includes('100')).toBe(false);
    expect(next.getIn([splitId, 'items']).includes('100')).toBe(false);
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['90', '80']));
    expect(next.getIn([splitId, 'items'])).toEqual(ImmutableList(['90', '80']));
  });

  it('restores history and parks statuses newer than the boundary as pending', () => {
    const state = withHome({
      items: ImmutableList(['110', '100', '90', '80']),
      pendingItems: ImmutableList(['120']),
      splitTimelineId: splitId,
      online: true,
      top: true,
      unread: 1,
    }, {
      [splitId]: timeline({
        items: ImmutableList(['100', '90', '80', '70', '60']),
        pendingItems: ImmutableList(),
        splitBoundaryId: '100',
        hasMore: false,
        isPartial: true,
        online: false,
        top: false,
      }),
    });

    const next = destroySplit(state);

    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['100', '90', '80', '70', '60']));
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['120', '110']));
    expect(next.getIn(['home', 'unread'])).toBe(2);
    expect(next.getIn(['home', 'top'])).toBe(false);
    expect(next.getIn(['home', 'hasMore'])).toBe(false);
    expect(next.getIn(['home', 'isPartial'])).toBe(true);
    expect(next.getIn(['home', 'online'])).toBe(true);
    expect(next.getIn(['home', 'splitTimelineId'])).toBeUndefined();
    expect(next.get(splitId)).toBeUndefined();
  });

  it('materializes the live pane and drops history-only statuses', () => {
    const state = withHome({
      items: ImmutableList(['100', '90', '80']),
      pendingItems: ImmutableList(['120', '110', '100']),
      splitTimelineId: splitId,
      online: true,
      top: true,
      unread: 2,
      hasMore: true,
    }, {
      [splitId]: timeline({
        items: ImmutableList(['100', '90', '80', '70', '60']),
        pendingItems: ImmutableList(),
        splitBoundaryId: '100',
        hasMore: false,
        online: false,
        top: false,
      }),
    });

    const next = timelines(state, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop: false,
    });

    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['120', '110', '100', '90', '80']));
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList());
    expect(next.getIn(['home', 'unread'])).toBe(0);
    expect(next.getIn(['home', 'top'])).toBe(false);
    expect(next.getIn(['home', 'hasMore'])).toBe(true);
    expect(next.getIn(['home', 'online'])).toBe(true);
    expect(next.getIn(['home', 'splitTimelineId'])).toBeUndefined();
    expect(next.get(splitId)).toBeUndefined();
    expect(next.getIn(['home', 'items']).includes('70')).toBe(false);
    expect(next.getIn(['home', 'items']).includes('60')).toBe(false);
  });

  it('records whether the kept live pane was scrolled to the top', () => {
    const state = withHome({
      items: ImmutableList(['100']),
      pendingItems: ImmutableList(),
      splitTimelineId: splitId,
      top: false,
    }, {
      [splitId]: timeline({
        items: ImmutableList(['100', '70']),
        splitBoundaryId: '100',
      }),
    });

    const next = timelines(state, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop: true,
    });

    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['100']));
    expect(next.getIn(['home', 'top'])).toBe(true);
    expect(next.get(splitId)).toBeUndefined();
  });

  it('does not merge a partial snapshot when keeping the live pane', () => {
    const state = withHome({
      items: ImmutableList(['100']),
      pendingItems: ImmutableList(['120']),
      splitTimelineId: splitId,
      isPartial: true,
      online: true,
      top: false,
      unread: 1,
      hasMore: true,
    }, {
      [splitId]: timeline({
        items: ImmutableList(['100', '70']),
        splitBoundaryId: '100',
        hasMore: false,
      }),
    });

    const next = timelines(state, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop: true,
    });

    expect(next.getIn(['home', 'isPartial'])).toBe(true);
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['100']));
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['120']));
    expect(next.getIn(['home', 'unread'])).toBe(1);
    expect(next.getIn(['home', 'top'])).toBe(false);
    expect(next.getIn(['home', 'hasMore'])).toBe(true);
    expect(next.getIn(['home', 'splitTimelineId'])).toBeUndefined();
    expect(next.get(splitId)).toBeUndefined();
  });

  it('leaves the active split alone when a stale live close arrives', () => {
    const split = createSplit(initial());
    const next = timelines(split, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: 'home:split:stale',
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop: true,
    });

    expect(next.getIn(['home', 'splitTimelineId'])).toBe(splitId);
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['110', '105']));
    expect(next.get(splitId)).toBe(split.get(splitId));
  });

  it('uses the first non-null status as the split boundary', () => {
    const state = withHome({
      items: ImmutableList([null, '100', null, '90']),
      pendingItems: ImmutableList([null, '120']),
    });
    const split = createSplit(state);

    expect(split.getIn([splitId, 'splitBoundaryId'])).toBe('100');

    const next = destroySplit(split);

    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList([null, '100', null, '90']));
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['120']));
    expect(next.get(splitId)).toBeUndefined();
  });

  it('does not duplicate an id that is already in history when restoring pending', () => {
    const state = withHome({
      items: ImmutableList(['120', '100', '90']),
      pendingItems: ImmutableList(['120', '110']),
      splitTimelineId: splitId,
      online: true,
    }, {
      [splitId]: timeline({
        items: ImmutableList(['120', '100', '90', '80']),
        splitBoundaryId: '100',
      }),
    });

    const next = destroySplit(state);

    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['110']));
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['120', '100', '90', '80']));
  });

  it('can create and destroy a split of an empty timeline', () => {
    const split = createSplit(withHome({
      items: ImmutableList(),
      pendingItems: ImmutableList(),
      online: true,
      top: true,
    }));

    expect(split.getIn([splitId, 'splitBoundaryId'])).toBe(null);
    expect(split.getIn([splitId, 'items'])).toEqual(ImmutableList());

    const withNewStatus = split.setIn(['home', 'items'], ImmutableList(['50']));
    const next = destroySplit(withNewStatus);

    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList());
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['50']));
    expect(next.getIn(['home', 'unread'])).toBe(1);
    expect(next.getIn(['home', 'top'])).toBe(false);
    expect(next.getIn(['home', 'splitTimelineId'])).toBeUndefined();
    expect(next.get(splitId)).toBeUndefined();
  });

  it('ignores a late expand from a destroyed session after a new split starts', () => {
    const cleared = destroySplit(createSplit(initial()));
    const secondId = 'home:split:X:session-b';
    const second = timelines(cleared, {
      type: TIMELINE_SPLIT_CREATE,
      sourceTimeline: 'home',
      splitTimeline: secondId,
    });
    const next = timelines(second, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: splitId,
      statuses: [{ id: '70' }, { id: '60' }],
      next: '/next',
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });

    expect(next).toBe(second);
    expect(next.get(splitId)).toBeUndefined();
    expect(next.getIn([secondId, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn(['home', 'splitTimelineId'])).toBe(secondId);
  });

  it('keeps a partial canonical timeline when the split is destroyed', () => {
    const split = createSplit(withHome({
      items: ImmutableList(['100', '90', '80']),
      pendingItems: ImmutableList(['110']),
      online: true,
      top: false,
      hasMore: true,
      unread: 1,
    }));
    const partial = timelines(split, {
      type: TIMELINE_MARK_AS_PARTIAL,
      timeline: 'home',
    });

    expect(partial.getIn(['home', 'isPartial'])).toBe(true);
    expect(partial.getIn(['home', 'items'])).toEqual(ImmutableList());
    expect(partial.getIn(['home', 'splitTimelineId'])).toBe(splitId);
    expect(partial.getIn([splitId, 'items'])).toEqual(ImmutableList(['100', '90', '80']));

    const next = destroySplit(partial);

    expect(next.getIn(['home', 'isPartial'])).toBe(true);
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList());
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList());
    expect(next.getIn(['home', 'unread'])).toBe(0);
    expect(next.getIn(['home', 'online'])).toBe(true);
    expect(next.getIn(['home', 'hasMore'])).toBe(true);
    expect(next.getIn(['home', 'splitTimelineId'])).toBeUndefined();
    expect(next.get(splitId)).toBeUndefined();
  });

  it('ignores a late expand for a split timeline that was already destroyed', () => {
    const split = createSplit(initial());
    const restored = destroySplit(split);
    const next = timelines(restored, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: splitId,
      statuses: [{ id: '70' }],
      next: null,
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });

    expect(next.get(splitId)).toBeUndefined();
    expect(next.getIn(['home', 'items']).includes('70')).toBe(false);
    expect(next).toBe(restored);
  });

  it('ignores a late scroll update so the removed history timeline is not recreated', () => {
    const restored = timelines(createSplit(initial()), { type: TIMELINE_SPLIT_DESTROY, sourceTimeline: 'home', splitTimeline: splitId });
    const next = timelines(restored, {
      type: TIMELINE_SCROLL_TOP,
      timeline: splitId,
      top: false,
    });

    expect(next.get(splitId)).toBeUndefined();
    expect(next).toBe(restored);
  });

  it.each([
    ACCOUNT_UNFOLLOW_SUCCESS,
    ACCOUNT_UNSUBSCRIBE_SUCCESS,
  ])('filters %s out of home and the active history timeline', (type) => {
    const split = createSplit(withHome({
      items: ImmutableList(['100', '90']),
      pendingItems: ImmutableList(['110']),
    }));
    const next = timelines(split, {
      type,
      relationship: { id: '2' },
      statuses: fromJS({
        '110': { id: '110', account: '2' },
        '100': { id: '100', account: '2' },
        '90': { id: '90', account: '3' },
      }),
    });

    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['90']));
    expect(next.getIn(['home', 'pendingItems'])).toEqual(ImmutableList());
    expect(next.getIn([splitId, 'items'])).toEqual(ImmutableList(['90']));
  });

  it.each([
    ACCOUNT_UNFOLLOW_SUCCESS,
    ACCOUNT_UNSUBSCRIBE_SUCCESS,
  ])('filters %s out of limited, its pending items, and the active history timeline', (type) => {
    const limitedSplitId = 'limited:split:column-a:uuid-1';
    const next = timelines(ImmutableMap({
      home: ImmutableMap({
        items: ImmutableList(['1']),
        pendingItems: ImmutableList(),
      }),
      limited: ImmutableMap({
        items: ImmutableList(['100', '90']),
        pendingItems: ImmutableList(['110']),
        splitTimelineId: limitedSplitId,
      }),
      [limitedSplitId]: ImmutableMap({
        items: ImmutableList(['100', '90']),
        pendingItems: ImmutableList(),
      }),
    }), {
      type,
      relationship: { id: '2' },
      statuses: fromJS({
        '110': { id: '110', account: '2' },
        '100': { id: '100', account: '2' },
        '90': { id: '90', account: '3' },
        '1': { id: '1', account: '9' },
      }),
    });

    expect(next.getIn(['limited', 'items'])).toEqual(ImmutableList(['90']));
    expect(next.getIn(['limited', 'pendingItems'])).toEqual(ImmutableList());
    expect(next.getIn([limitedSplitId, 'items'])).toEqual(ImmutableList(['90']));
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['1']));
  });

  it('keeps a return anchor when the split timeline is destroyed', () => {
    const anchor = ImmutableMap({
      locationKey: 'A',
      id: '90',
      offset: -7.84,
      fallbackOffset: 2386,
    });
    const split = timelines(createSplit(initial()), {
      type: TIMELINE_SPLIT_SAVE_RETURN_ANCHOR,
      timeline: 'home',
      anchor: anchor.toJS(),
    });
    const next = destroySplit(split);

    expect(next.get(splitId)).toBeUndefined();
    expect(next.getIn(['home', 'splitTimelineId'])).toBeUndefined();
    expect(next.getIn(['home', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn(['home', 'splitReturnAnchor'])).toEqual(anchor);
  });

  it('drops a return anchor when a new split is created or home becomes partial', () => {
    const saved = timelines(initial(), {
      type: TIMELINE_SPLIT_SAVE_RETURN_ANCHOR,
      timeline: 'home',
      anchor: { locationKey: 'A', id: '90', offset: -7.84, fallbackOffset: 2386 },
    });
    const created = createSplit(saved);
    const cleared = timelines(saved, {
      type: TIMELINE_MARK_AS_PARTIAL,
      timeline: 'home',
    });
    const explicit = timelines(saved, {
      type: TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR,
      timeline: 'home',
    });

    expect(created.getIn(['home', 'splitReturnAnchor'])).toBeUndefined();
    expect(created.getIn(['home', 'splitTimelineId'])).toBe(splitId);
    expect(cleared.getIn(['home', 'splitReturnAnchor'])).toBeUndefined();
    expect(cleared.getIn(['home', 'isPartial'])).toBe(true);
    expect(explicit.getIn(['home', 'splitReturnAnchor'])).toBeUndefined();
  });
});

describe('timeline split for a colon-delimited list source', () => {
  const source = 'list:42';
  const session1 = 'list:42:split:column-a:uuid-1';
  const session2 = 'list:42:split:column-a:uuid-2';

  const listState = (overrides = {}) => ImmutableMap({
    [source]: timeline({
      items: ImmutableList(['100', '90', '80']),
      pendingItems: ImmutableList(['110']),
      online: true,
      top: true,
      unread: 1,
      hasMore: true,
      ...overrides,
    }),
  });

  const createListSplit = (state, splitTimeline = session1) => timelines(state, {
    type: TIMELINE_SPLIT_CREATE,
    sourceTimeline: source,
    splitTimeline,
  });

  it('creates a list split using the full list id as the source', () => {
    const next = createListSplit(listState());

    expect(next.get('list')).toBeUndefined();
    expect(next.getIn([source, 'splitTimelineId'])).toBe(session1);
    expect(next.getIn([source, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn([session1, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn([session1, 'splitBoundaryId'])).toBe('100');
  });

  it('queues a streaming update onto the canonical list while split even when pending items are disabled', () => {
    const split = createListSplit(listState({
      pendingItems: ImmutableList(),
      top: true,
      unread: 0,
    }));
    const next = timelines(split, {
      type: TIMELINE_UPDATE,
      timeline: source,
      status: { id: '120' },
      usePendingItems: false,
    });

    expect(next.getIn([source, 'pendingItems'])).toEqual(ImmutableList(['120']));
    expect(next.getIn([source, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn([session1, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(next.getIn([session1, 'pendingItems'])).toEqual(ImmutableList());
  });

  it('restores history onto the canonical list and keeps newer live items pending', () => {
    const split = createListSplit(listState());
    const live = timelines(split, {
      type: TIMELINE_UPDATE,
      timeline: source,
      status: { id: '130' },
      usePendingItems: false,
    });
    const expanded = timelines(live, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: session1,
      statuses: [{ id: '70' }],
      next: null,
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });
    const next = timelines(expanded, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: source,
      splitTimeline: session1,
    });

    expect(next.get(session1)).toBeUndefined();
    expect(next.getIn([source, 'splitTimelineId'])).toBeUndefined();
    expect(next.getIn([source, 'items'])).toEqual(ImmutableList(['100', '90', '80', '70']));
    expect(next.getIn([source, 'pendingItems'])).toEqual(ImmutableList(['130', '110']));
  });

  it('accepts load-more for the active session and rejects a stale session after a new split', () => {
    const first = createListSplit(listState());
    const accepted = timelines(first, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: session1,
      statuses: [{ id: '70' }],
      next: null,
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });

    expect(accepted.getIn([session1, 'items'])).toEqual(ImmutableList(['100', '90', '80', '70']));
    expect(accepted.getIn([source, 'items'])).toEqual(ImmutableList(['100', '90', '80']));

    const cleared = timelines(first, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: source,
      splitTimeline: session1,
    });
    const second = createListSplit(cleared, session2);
    const stale = timelines(second, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: session1,
      statuses: [{ id: '70' }, { id: '60' }],
      next: '/next',
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });

    expect(stale).toBe(second);
    expect(stale.get(session1)).toBeUndefined();
    expect(stale.getIn([session2, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(stale.getIn([source, 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(stale.getIn([source, 'splitTimelineId'])).toBe(session2);
  });

  it('clears a list return anchor when a new split is created or the list becomes partial', () => {
    const saved = timelines(listState(), {
      type: TIMELINE_SPLIT_SAVE_RETURN_ANCHOR,
      timeline: source,
      anchor: { locationKey: 'A', id: '90', offset: -4, fallbackOffset: 10 },
    });
    const created = createListSplit(saved);
    const partial = timelines(saved, {
      type: TIMELINE_MARK_AS_PARTIAL,
      timeline: source,
    });

    expect(saved.getIn([source, 'splitReturnAnchor', 'locationKey'])).toBe('A');
    expect(created.getIn([source, 'splitReturnAnchor'])).toBeUndefined();
    expect(created.getIn([source, 'splitTimelineId'])).toBe(session1);
    expect(partial.getIn([source, 'splitReturnAnchor'])).toBeUndefined();
    expect(partial.getIn([source, 'isPartial'])).toBe(true);
  });
});
