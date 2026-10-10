jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { List as ImmutableList, fromJS } from 'immutable';
import { mixTimelineView } from '../../mix/view';
import reducer from '../mix_timelines';
import {
  MIX_DISPLAY_HISTORY,
  MIX_SOURCE_FAIL,
  MIX_SOURCE_SUCCESS,
  MIX_SPLIT_ANCHOR,
  MIX_SPLIT_CLEAR_ANCHOR,
  MIX_SPLIT_CREATE,
  MIX_SPLIT_DESTROY,
  MIX_STREAM_EDIT,
  MIX_STREAM_REMOVE,
  MIX_STREAM_STATUS,
  MIX_STREAM_SYNC,
  MIX_TIMELINE_CLOSE,
  MIX_TIMELINE_OPEN,
} from '../../actions/mix_timelines';

const fingerprint = 'public\nlist';

const open = () => reducer(undefined, {
  type: MIX_TIMELINE_OPEN,
  columnKey: 'column:a',
  mixId: 'mix-1',
  definitionFingerprint: fingerprint,
  sessionId: 1,
  sources: [
    { key: 'public', descriptor: { type: 'public', params: {} } },
    { key: 'list', descriptor: { type: 'list', id: '4', params: {} } },
  ],
});

const succeed = (state, key, ids, extra = {}) => reducer(state, {
  type: MIX_SOURCE_SUCCESS,
  columnKey: 'column:a',
  sourceKey: key,
  sessionId: 1,
  definitionFingerprint: fingerprint,
  ids,
  cursor: ids[ids.length - 1] || null,
  frontier: ids[ids.length - 1] || null,
  hasMore: true,
  partial: false,
  requestedCursor: '900',
  ...extra,
});

describe('mix live history split', () => {
  it('snapshots history without pending posts and keeps cursors independent', () => {
    let state = succeed(succeed(open(), 'public', ['40', '30']), 'list', ['35']);

    state = reducer(state, {
      type: MIX_STREAM_STATUS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: '80',
      decision: 'accept',
      filterResults: [],
    });
    state = state.setIn(['column:a', 'pinnedToTop'], false);
    state = reducer(state, {
      type: MIX_STREAM_STATUS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: '90',
      decision: 'accept',
      filterResults: [],
    });
    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'column:a:split:1:s',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      boundaryId: '80',
      frozenLive: { public: { ids: ['80'], filterResults: {} } },
    });
    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      scope: 'history',
      splitId: 'column:a:split:1:s',
      ids: ['20'],
      cursor: '20',
      frontier: '20',
      hasMore: true,
      partial: false,
      requestedCursor: '30',
    });

    expect(state.getIn(['column:a', 'split', 'history', 'frozenLive', 'public', 'ids']).toArray()).toEqual(['80']);
    expect(state.getIn(['column:a', 'pendingStatusIds']).toArray()).toEqual(['90']);
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'ids']).toArray()).toEqual(['40', '30', '20']);
    expect(state.getIn(['column:a', 'sources', 'public', 'cursor'])).toBe('30');
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'cursor'])).toBe('20');
    expect(state.getIn(['column:a', 'sources', 'public', 'gap'])).toBe(false);

    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      scope: 'history',
      splitId: 'old',
      ids: ['5'],
      cursor: '5',
      frontier: '5',
      hasMore: false,
      partial: false,
      requestedCursor: '20',
    });
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'ids']).toArray()).not.toContain('5');
  });

  it('keeps history on one close and live on the other without duplicating ids', () => {
    let state = succeed(succeed(open(), 'public', ['40']), 'list', ['35'], { hasMore: false });

    state = reducer(state, {
      type: MIX_STREAM_STATUS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: '90',
      decision: 'accept',
      filterResults: [],
    });
    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-1',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: { public: { ids: ['90'], filterResults: {} } },
    });
    state = reducer(state, {
      type: MIX_STREAM_STATUS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: '100',
      decision: 'accept',
      filterResults: [],
    });

    const keptHistory = reducer(state, {
      type: MIX_SPLIT_DESTROY,
      columnKey: 'column:a',
      splitId: 'split-1',
      keep: 'history',
      sessionId: 1,
      definitionFingerprint: fingerprint,
    });

    expect(keptHistory.getIn(['column:a', 'split'])).toBeUndefined();
    expect(keptHistory.getIn(['column:a', 'sources', 'public', 'ids']).toArray()).toEqual(['40']);
    expect(keptHistory.getIn(['column:a', 'pendingStatusIds']).toArray()).toEqual(['100']);
    expect(keptHistory.getIn(['column:a', 'pinnedToTop'])).toBe(false);
    expect(keptHistory.getIn(['column:a', 'live', 'public', 'statusIds']).toArray()).toEqual(['90', '100']);

    const keptLive = reducer(state, {
      type: MIX_SPLIT_DESTROY,
      columnKey: 'column:a',
      splitId: 'split-1',
      keep: 'live',
      liveAtTop: true,
      sessionId: 1,
      definitionFingerprint: fingerprint,
    });

    expect(keptLive.getIn(['column:a', 'displayMode'])).toBe('live');
    expect(keptLive.getIn(['column:a', 'pendingStatusIds']).toArray()).toEqual([]);
    expect(keptLive.getIn(['column:a', 'sources', 'public', 'ids']).toArray()).toEqual(['40']);
    expect(keptLive.getIn(['column:a', 'split'])).toBeUndefined();
    expect(mixTimelineView(keptLive.get('column:a'), null, null, '1').statusIds.toArray()).toEqual(['100', '90', '40', '35']);

    const restored = reducer(keptLive, {
      type: MIX_DISPLAY_HISTORY,
      columnKey: 'column:a',
      sessionId: 1,
      definitionFingerprint: fingerprint,
    });

    expect(restored.getIn(['column:a', 'displayMode'])).toBe(null);
    expect(mixTimelineView(restored.get('column:a'), null, null, '1').statusIds.toArray()).toEqual(['100', '90', '40']);
  });

  it('removes an edited history membership without moving the history cursor', () => {
    let state = succeed(succeed(open(), 'public', ['500'], { cursor: '400', frontier: '400', partial: true }), 'list', ['35'], { hasMore: false });

    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-1',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: {},
    });
    state = reducer(state, {
      type: MIX_STREAM_EDIT,
      columnKey: 'column:a',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: '500',
      decisions: [{ sourceKey: 'public', decision: 'reject', filterResults: [] }],
    });

    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'ids']).toArray()).toEqual([]);
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'cursor'])).toBe('400');
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'frontier'])).toBe(null);
    expect(state.getIn(['column:a', 'sources', 'public', 'gap'])).toBe(true);

    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      scope: 'history',
      splitId: 'split-1',
      ids: ['500'],
      cursor: '500',
      frontier: '500',
      hasMore: false,
      partial: false,
      requestedCursor: '400',
    });
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'ids']).toArray()).toEqual([]);
    expect(ImmutableList.isList(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'ids']))).toBe(true);
  });

  it('does not split before the first load, and a gap stays unordered', () => {
    const waiting = reducer(open(), {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-1',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: {},
    });

    expect(waiting.getIn(['column:a', 'split'])).toBeUndefined();

    let state = succeed(succeed(open(), 'public', ['40'], { partial: true, frontier: null, cursor: '40' }), 'list', ['35'], { hasMore: false, frontier: '35' });

    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-1',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: {},
    });

    const history = mixTimelineView(state.get('column:a'), null, null, '1', 'history');

    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'gap'])).toBe(true);
    expect(history.orderGuaranteed).toBe(false);
    expect(history.statusIds.toArray()).toEqual(expect.arrayContaining(['40']));

    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      scope: 'history',
      splitId: 'split-1',
      ids: ['20'],
      cursor: '20',
      frontier: '20',
      hasMore: true,
      partial: false,
      requestedCursor: '40',
    });

    expect(state.getIn(['column:a', 'sources', 'public', 'gap'])).toBe(true);
    expect(state.getIn(['column:a', 'sources', 'public', 'cursor'])).toBe('40');
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'gap'])).toBe(true);
    expect(mixTimelineView(state.get('column:a'), null, null, '1', 'history').orderGuaranteed).toBe(false);
    expect(mixTimelineView(state.get('column:a'), null, null, '1', 'live').statusIds.toArray()).not.toContain('20');
  });

  it('keeps a history rate limit off the live pane and a live gap off the history pane', () => {
    let state = succeed(succeed(open(), 'public', ['40']), 'list', ['35']);

    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-1',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: {},
    });
    state = reducer(state, {
      type: MIX_STREAM_SYNC,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      syncState: 'degraded',
      connected: true,
    });
    state = reducer(state, {
      type: MIX_SOURCE_FAIL,
      columnKey: 'column:a',
      sourceKey: 'list',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      scope: 'history',
      splitId: 'split-1',
      error: 'rate_limit',
      retryAt: 9_000,
    });

    const history = mixTimelineView(state.get('column:a'), null, null, '1', 'history');
    const live = mixTimelineView(state.get('column:a'), null, null, '1', 'live');

    expect(state.getIn(['column:a', 'sources', 'list', 'error'])).toBe(null);
    expect(state.getIn(['column:a', 'live', 'public', 'syncState'])).toBe('degraded');
    expect(history.errors.map(item => item.error)).toEqual(['rate_limit']);
    expect(history.degraded).toEqual([]);
    expect(live.errors).toEqual([]);
    expect(live.degraded).toEqual(['public']);
    expect(live.orderGuaranteed).toBe(true);
  });

  it('shows the newest forty live posts once, including posts held as pending', () => {
    let state = succeed(succeed(open(), 'public', ['10'], { hasMore: false }), 'list', ['11'], { hasMore: false });
    const ids = [];

    for (let value = 50; value <= 94; value += 1) {
      ids.push(String(value));
    }

    state = state
      .setIn(['column:a', 'live', 'public', 'statusIds'], ImmutableList(ids))
      .setIn(['column:a', 'live', 'list', 'statusIds'], ImmutableList(['94', '93']))
      .setIn(['column:a', 'pendingStatusIds'], ImmutableList(['94']));
    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-1',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: { public: { ids: ['50'], filterResults: {} } },
    });

    const live = mixTimelineView(state.get('column:a'), null, null, '1', 'live');
    const history = mixTimelineView(state.get('column:a'), null, null, '1', 'history');
    const single = mixTimelineView(state.get('column:a'), null, null, '1');

    expect(live.statusIds.size).toBe(40);
    expect(live.statusIds.first()).toBe('94');
    expect(live.statusIds.toArray().filter(id => id === '94')).toEqual(['94']);
    expect(live.sourceKeysById['93']).toEqual(['public', 'list']);
    expect(live.statusIds.contains('50')).toBe(false);
    expect(single.statusIds.contains('94')).toBe(false);
    expect(history.statusIds.contains('94')).toBe(false);
    expect(history.statusIds.contains('50')).toBe(true);
    expect(history.statusIds.contains('10')).toBe(true);
  });

  it('drops a deleted history post and does not restore it from a late page', () => {
    let state = succeed(succeed(open(), 'public', ['40', '30']), 'list', ['35']);

    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-1',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: { public: { ids: ['80'], filterResults: {} } },
    });
    state = reducer(state, {
      type: MIX_STREAM_REMOVE,
      columnKey: 'column:a',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: '40',
      reason: 'expire',
    });
    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      scope: 'history',
      splitId: 'split-1',
      ids: ['40', '20'],
      cursor: '20',
      frontier: '20',
      hasMore: false,
      partial: false,
      requestedCursor: '30',
    });

    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'ids']).toArray()).toEqual(['30', '20']);
    expect(state.getIn(['column:a', 'deletedStatusIds']).toArray()).toEqual(['40']);
    expect(mixTimelineView(state.get('column:a'), null, null, '1', 'history').statusIds.contains('40')).toBe(false);
  });

  it('updates a filter result stored only on the history snapshot', () => {
    let state = succeed(succeed(open(), 'public', ['40'], { hasMore: false }), 'list', ['35'], { hasMore: false });

    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-1',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: { public: { ids: ['80'], filterResults: {} } },
    });
    state = reducer(state, {
      type: MIX_STREAM_EDIT,
      columnKey: 'column:a',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: '80',
      decisions: [{ sourceKey: 'public', decision: 'accept', filterResults: [{ filter: '2' }] }],
    });

    expect(state.getIn(['column:a', 'split', 'history', 'frozenLive', 'public', 'ids']).toArray()).toEqual(['80']);
    expect(state.getIn(['column:a', 'split', 'history', 'frozenLive', 'public', 'filterResults', '80', 0, 'filter'])).toBe('2');
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'cursor'])).toBe('40');

    const hidden = mixTimelineView(state.get('column:a'), null, fromJS({
      2: { id: '2', title: 'spam', filter_action: 'hide', context: ['public'] },
    }), '1', 'history');

    expect(hidden.statusIds.contains('80')).toBe(false);
    expect(hidden.statusIds.contains('40')).toBe(true);
  });

  it('keeps a second column independent and keeps the return anchor after close', () => {
    let state = succeed(succeed(open(), 'public', ['40'], { hasMore: false }), 'list', ['35'], { hasMore: false });

    state = reducer(state, {
      type: MIX_TIMELINE_OPEN,
      columnKey: 'column:b',
      mixId: 'mix-1',
      definitionFingerprint: fingerprint,
      sessionId: 2,
      sources: [
        { key: 'public', descriptor: { type: 'public', params: {} } },
        { key: 'list', descriptor: { type: 'list', id: '4', params: {} } },
      ],
    });
    state = reducer(state, {
      type: MIX_SPLIT_CREATE,
      columnKey: 'column:a',
      splitId: 'split-a',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      frozenLive: {},
    });
    state = reducer(state, {
      type: MIX_STREAM_STATUS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: '100',
      decision: 'accept',
      filterResults: [],
    });
    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: 'public',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      scope: 'history',
      splitId: 'split-a',
      ids: ['20'],
      cursor: '20',
      frontier: '20',
      hasMore: true,
      partial: false,
      requestedCursor: '40',
    });
    state = reducer(state, {
      type: MIX_SPLIT_ANCHOR,
      columnKey: 'column:a',
      anchor: { locationKey: 'route-a', id: '40', offset: 12, fallbackOffset: 80 },
    });

    expect(state.getIn(['column:b', 'split'])).toBeUndefined();
    expect(state.getIn(['column:b', 'live', 'public', 'statusIds'])).toBeUndefined();
    expect(state.getIn(['column:a', 'split', 'history', 'sources', 'public', 'ids']).toArray()).toEqual(['40', '20']);

    state = reducer(state, { type: MIX_TIMELINE_CLOSE, columnKey: 'column:a' });

    expect(state.get('column:a')).toBeUndefined();
    expect(state.getIn(['__anchors', 'column:a', 'locationKey'])).toBe('route-a');
    expect(state.getIn(['__anchors', 'column:a', 'id'])).toBe('40');
    expect(state.has('column:b')).toBe(true);

    state = reducer(state, { type: MIX_SPLIT_CLEAR_ANCHOR, columnKey: 'column:a' });
    expect(state.getIn(['__anchors', 'column:a'])).toBeUndefined();
  });

  it('keeps the reading position unpinned unless history was at the top with no fresh posts', () => {
    const split = (extraLive) => {
      let state = succeed(succeed(open(), 'public', ['40'], { hasMore: false }), 'list', ['35'], { hasMore: false });

      state = reducer(state, {
        type: MIX_SPLIT_CREATE,
        columnKey: 'column:a',
        splitId: 'split-1',
        sessionId: 1,
        definitionFingerprint: fingerprint,
        frozenLive: {},
      });

      if (extraLive) {
        state = reducer(state, {
          type: MIX_STREAM_STATUS,
          columnKey: 'column:a',
          sourceKey: 'public',
          sessionId: 1,
          definitionFingerprint: fingerprint,
          id: '100',
          decision: 'accept',
          filterResults: [],
        });
      }

      return state;
    };

    const closeHistory = (state, historyAtTop) => reducer(state, {
      type: MIX_SPLIT_DESTROY,
      columnKey: 'column:a',
      splitId: 'split-1',
      keep: 'history',
      historyAtTop,
      sessionId: 1,
      definitionFingerprint: fingerprint,
    });

    const atTop = closeHistory(split(false), true);
    const midway = closeHistory(split(false), false);
    const withFresh = closeHistory(split(true), true);

    expect(atTop.getIn(['column:a', 'pinnedToTop'])).toBe(true);
    expect(atTop.getIn(['column:a', 'pendingStatusIds']).toArray()).toEqual([]);
    expect(midway.getIn(['column:a', 'pinnedToTop'])).toBe(false);
    expect(midway.getIn(['column:a', 'pendingStatusIds']).toArray()).toEqual([]);
    expect(withFresh.getIn(['column:a', 'pinnedToTop'])).toBe(false);
    expect(withFresh.getIn(['column:a', 'pendingStatusIds']).toArray()).toEqual(['100']);
  });
});
