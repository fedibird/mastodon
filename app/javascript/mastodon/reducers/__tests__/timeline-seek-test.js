import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import { TIMELINE_SPLIT_CREATE, TIMELINE_SPLIT_DESTROY, TIMELINE_SPLIT_KEEP_HISTORY, TIMELINE_SPLIT_KEEP_LIVE } from '../../actions/timelines';
import { WINDOW_SEEK_BEGIN, WINDOW_SEEK_COMMIT, WINDOW_SEEK_FAIL, WINDOW_SEEK_RESTORE, WINDOW_SEEK_SCROLL } from '../../timeline_seek/constants';
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

  it('fails a commit newer than the split boundary and leaves the live rows alone', () => {
    const split = create(withHome());
    const beforeItems = split.getIn([splitId, 'items']);
    const beforeAnchor = split.getIn([splitId, 'window', 'anchorId']);
    const begun = timelines(split, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
    });
    const rejected = timelines(begun, {
      type: WINDOW_SEEK_COMMIT,
      timeline: splitId,
      sessionId: 'seek-1',
      source: sourceKey,
      anchorId: '500',
      newerIds: ['600'],
      olderIds: ['100'],
      limit: 40,
      capability: 'database',
    });

    expect(split.getIn([splitId, 'window', 'boundaryId'])).toBe('300');
    expect(rejected.getIn([splitId, 'items'])).toEqual(beforeItems);
    expect(rejected.getIn([splitId, 'window', 'anchorId'])).toBe(beforeAnchor);
    expect(rejected.getIn([splitId, 'window', 'seeking'])).toBe(false);
    expect(rejected.getIn([splitId, 'seek', 'phase'])).toBe('unavailable');
    expect(rejected.getIn([splitId, 'seek', 'reason'])).toBe('newer_than_split_boundary');
    expect(rejected.getIn([splitId, 'seek', 'phase'])).not.toBe('pending');
    expect(rejected.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['400']));
    expect(rejected.getIn(['home', 'items'])).toEqual(ids);
  });

  it('records one scroll result for the committed revision and ignores a stale session', () => {
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
      newerIds: [],
      olderIds: ['8'],
      limit: 40,
      capability: 'database',
    });
    const revision = committed.getIn([splitId, 'window', 'revision']);
    const stale = timelines(committed, {
      type: WINDOW_SEEK_SCROLL,
      timeline: splitId,
      sessionId: 'seek-0',
      revision,
      reason: 'loaded',
      scrolled: true,
    });
    const settled = timelines(stale, {
      type: WINDOW_SEEK_SCROLL,
      timeline: splitId,
      sessionId: 'seek-1',
      revision,
      reason: 'filtered',
      scrolled: false,
    });

    expect(committed.getIn([splitId, 'seek', 'scrollStatus'])).toBe('pending');
    expect(stale.getIn([splitId, 'seek', 'scrollStatus'])).toBe('pending');
    expect(settled.getIn([splitId, 'seek', 'scrollStatus'])).toBe('filtered');
    expect(settled.getIn([splitId, 'seek', 'scrollReason'])).toBe('filtered');
    expect(settled.getIn([splitId, 'items'])).toEqual(committed.getIn([splitId, 'items']));
    expect(settled.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['400']));
  });

  it('restores the history window when a jump row is filtered and leaves a loaded jump in place', () => {
    const split = create(withHome());
    const beforeItems = split.getIn([splitId, 'items']);
    const beforeWindow = split.getIn([splitId, 'window']);
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
      anchorId: '50',
      newerIds: ['60'],
      olderIds: ['40'],
      limit: 40,
      capability: 'approximate',
    });
    const filtered = timelines(committed, {
      type: WINDOW_SEEK_SCROLL,
      timeline: splitId,
      sessionId: 'seek-1',
      revision: committed.getIn([splitId, 'window', 'revision']),
      reason: 'filtered',
      scrolled: false,
    });
    const restored = timelines(filtered, {
      type: WINDOW_SEEK_RESTORE,
      timeline: splitId,
      sessionId: 'seek-1',
      items: beforeItems,
      windowState: beforeWindow,
      reason: 'filtered',
    });

    expect(restored.getIn([splitId, 'items'])).toEqual(beforeItems);
    expect(restored.getIn([splitId, 'window', 'anchorId'])).toBe(beforeWindow.get('anchorId'));
    expect(restored.getIn([splitId, 'seek', 'restored'])).toBe(true);
    expect(restored.getIn(['home', 'items'])).toEqual(ids);
    expect(restored.getIn(['home', 'pendingItems'])).toEqual(ImmutableList(['400']));

    const loaded = timelines(committed, {
      type: WINDOW_SEEK_SCROLL,
      timeline: splitId,
      sessionId: 'seek-1',
      revision: committed.getIn([splitId, 'window', 'revision']),
      reason: 'loaded',
      scrolled: true,
    });
    const kept = timelines(loaded, {
      type: WINDOW_SEEK_RESTORE,
      timeline: splitId,
      sessionId: 'seek-1',
      items: beforeItems,
      windowState: beforeWindow,
      reason: 'filtered',
    });

    expect(kept.getIn([splitId, 'items'])).toEqual(committed.getIn([splitId, 'items']));
    expect(kept.getIn([splitId, 'seek', 'scrollStatus'])).toBe('loaded');
  });
});
