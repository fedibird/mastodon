import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import { TIMELINE_SPLIT_CREATE, TIMELINE_SPLIT_DESTROY, TIMELINE_SPLIT_KEEP_HISTORY, TIMELINE_SPLIT_KEEP_LIVE } from '../../actions/timelines';
import { WINDOW_SEEK_BEGIN, WINDOW_SEEK_COMMIT, WINDOW_SEEK_FAIL } from '../../timeline_seek/constants';
import { WINDOW_HISTORY_REQUEST, WINDOW_HISTORY_SUCCESS } from '../../windowed_history/types';
import timelines from '../timelines';
import { beginHistoryRequest } from '../../windowed_history/model';

const splitId = 'home:split:session';
const anchor = '200';
const ids = ImmutableList(['300', '200', '100']);

const withHome = () => ImmutableMap({
  home: ImmutableMap({
    unread: 1,
    online: true,
    top: false,
    isLoading: false,
    hasMore: true,
    pendingItems: ImmutableList(['400']),
    items: ids,
  }),
});

const create = (state) => timelines(state, {
  type: TIMELINE_SPLIT_CREATE,
  sourceTimeline: 'home',
  splitTimeline: splitId,
  anchorId: anchor,
});

const sourceKey = 'home?visibilities=[]';

describe('timeline seek reducer', () => {
  it('keeps the current rows when resolve fails', () => {
    const split = create(withHome());
    const beforeItems = split.getIn([splitId, 'items']);
    const beforeAnchor = split.getIn([splitId, 'window', 'anchorId']);
    const begun = timelines(split, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
    });
    const failed = timelines(begun, {
      type: WINDOW_SEEK_FAIL,
      timeline: splitId,
      sessionId: 'seek-1',
      outcome: 'unavailable',
      reason: 'outside_retained_range',
      capability: 'approximate',
      limitations: ['retention_2000'],
    });

    expect(failed.getIn([splitId, 'items'])).toEqual(beforeItems);
    expect(failed.getIn([splitId, 'window', 'anchorId'])).toBe(beforeAnchor);
    expect(failed.getIn([splitId, 'window', 'seeking'])).toBe(false);
    expect(failed.getIn([splitId, 'window', 'generation'])).toBe(split.getIn([splitId, 'window', 'generation']) + 1);
    expect(failed.getIn([splitId, 'seek', 'phase'])).toBe('unavailable');
    expect(failed.getIn(['home', 'items'])).toEqual(ids);
    expect(failed.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['400']));
  });

  it('drops a late page from the generation seek invalidated', () => {
    const split = create(withHome());
    const begun = timelines(split, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
    });
    const stale = timelines(begun, {
      type: WINDOW_HISTORY_SUCCESS,
      timeline: splitId,
      direction: 'older',
      requestId: 'old-page',
      generation: split.getIn([splitId, 'window', 'generation']),
      statuses: [{ id: '1' }],
      cursor: '100',
      limit: 20,
      capability: 'database',
    });

    expect(stale.getIn([splitId, 'items'])).toEqual(begun.getIn([splitId, 'items']));
    expect(beginHistoryRequest({
      seeking: true,
      newer: { status: 'open', requestId: null, cursor: '3' },
      older: { status: 'open', requestId: null, cursor: '1' },
    }, { direction: 'older', cursor: '1', requestId: 'next' }).accepted).toBe(false);
  });

  it('ignores an older seek commit after a newer seek starts', () => {
    const split = create(withHome());
    const first = timelines(split, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
    });
    const second = timelines(first, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-2',
      source: sourceKey,
    });
    const staleCommit = timelines(second, {
      type: WINDOW_SEEK_COMMIT,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
      anchorId: '7',
      newerIds: [],
      olderIds: ['6'],
      limit: 40,
      capability: 'database',
    });
    const fresh = timelines(staleCommit, {
      type: WINDOW_SEEK_COMMIT,
      timeline: splitId,
      sessionId: 'seek-2',
      source: sourceKey,
      anchorId: '9',
      newerIds: [],
      olderIds: ['8'],
      limit: 40,
      capability: 'redis',
    });

    expect(staleCommit.getIn([splitId, 'items'])).toEqual(second.getIn([splitId, 'items']));
    expect(fresh.getIn([splitId, 'items']).toArray()).toEqual(['9', '8']);
    expect(fresh.getIn([splitId, 'window', 'older', 'status'])).toBe('unavailable');
    expect(fresh.getIn([splitId, 'window', 'boundaryId'])).toBe(split.getIn([splitId, 'window', 'boundaryId']));
    expect(fresh.getIn(['home', 'items'])).toEqual(ids);
  });

  it('does not apply a commit after the split is closed', () => {
    const split = create(withHome());
    const begun = timelines(split, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
    });
    const closed = timelines(begun, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop: false,
    });
    const late = timelines(closed, {
      type: WINDOW_SEEK_COMMIT,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
      anchorId: '9',
      newerIds: [],
      olderIds: [],
      limit: 40,
      capability: 'database',
    });

    expect(late.get(splitId)).toBeUndefined();
    expect(late.getIn(['home', 'pendingItems'])).toEqual(ImmutableList());
    expect(late.getIn(['home', 'items'])).toEqual(ImmutableList(['400']).concat(ids));
  });

  it('keeps history on the source when a seek commit is the split window', () => {
    const split = create(withHome());
    const begun = timelines(split, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
    });
    const committed = timelines(begun, {
      type: WINDOW_SEEK_COMMIT,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
      anchorId: '9',
      newerIds: ['10'],
      olderIds: [],
      newerPartial: true,
      olderPartial: true,
      limit: 40,
      capability: 'database',
    });
    const restored = timelines(committed, {
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
      keep: TIMELINE_SPLIT_KEEP_HISTORY,
      liveAtTop: false,
    });

    expect(committed.getIn([splitId, 'window', 'older', 'status'])).toBe('paused');
    expect(committed.getIn(['home', 'items'])).toEqual(ids);
    expect(restored.getIn(['home', 'items']).toArray()).toEqual(expect.arrayContaining(['10', '9']));
    expect(restored.get(splitId)).toBeUndefined();
  });

  it('does not let a history request start while a seek is in flight', () => {
    const split = create(withHome());
    const begun = timelines(split, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
    });
    const blocked = timelines(begun, {
      type: WINDOW_HISTORY_REQUEST,
      timeline: splitId,
      direction: 'older',
      cursor: begun.getIn([splitId, 'window', 'oldestId']),
      requestId: 'page-during-seek',
      generation: begun.getIn([splitId, 'window', 'generation']),
    });

    expect(blocked.getIn([splitId, 'window', 'older', 'status'])).not.toBe('loading');
    expect(blocked.getIn([splitId, 'window', 'older', 'requestId'])).toBeNull();
  });
});
