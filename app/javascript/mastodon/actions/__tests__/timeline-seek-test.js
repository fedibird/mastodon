import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import timelines from '../../reducers/timelines';
import { publicHistoryContract } from '../../windowed_history/sources';
import { TIMELINE_SPLIT_CREATE, TIMELINE_SPLIT_DESTROY, TIMELINE_SPLIT_KEEP_LIVE } from '../timelines';
import { seekWindowedTimeline } from '../timeline_seek';
import { createSeekQuery } from '../../timeline_seek/query';
import { SEEK_KIND } from '../../timeline_seek/constants';

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: mockGet, post: mockPost })),
  getLinks: () => ({ refs: [] }),
}));

jest.mock('../importer', () => ({
  importFetchedStatuses: () => ({ type: 'IMPORT_STATUSES' }),
  importFetchedAccounts: () => ({ type: 'IMPORT_ACCOUNTS' }),
  importFetchedStatus: () => ({ type: 'IMPORT_STATUS' }),
}));

jest.mock('../accounts', () => ({
  fetchRelationshipsSuccess: () => ({ type: 'REL_SUCCESS' }),
  fetchRelationshipsFromStatuses: () => ({ type: 'REL_STATUSES' }),
}));

const splitId = 'public:split:session';
const anchor = '0000200';
const ids = ImmutableList(['0000300', anchor, '0000100']);

const root = (state = ImmutableMap(), action) => state.set('timelines', timelines(state.get('timelines'), action));

const storeWithSplit = () => {
  const state = ImmutableMap({
    timelines: ImmutableMap({
      public: ImmutableMap({
        unread: 0,
        online: true,
        top: true,
        isLoading: false,
        hasMore: true,
        pendingItems: ImmutableList(['0000400']),
        items: ids,
      }),
    }),
  });
  const store = createStore(root, state, applyMiddleware(thunk));

  store.dispatch({
    type: TIMELINE_SPLIT_CREATE,
    sourceTimeline: 'public',
    splitTimeline: splitId,
    anchorId: anchor,
  });

  return store;
};

const contract = publicHistoryContract({ onlyRemote: false, onlyMedia: false, withoutMedia: false, withoutBot: true });

const resolvedBody = {
  version: 1,
  outcome: 'resolved',
  capability: 'supported',
  precision: 'exact',
  anchor_id: '9007199254740993',
  display_row_id: '9007199254740993',
  limitations: [],
};

describe('seekWindowedTimeline', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
  });

  it('does not call the API or move the window for an unsupported source kind', async () => {
    const store = storeWithSplit();
    const before = store.getState().getIn(['timelines', splitId, 'items']);
    const result = await store.dispatch(seekWindowedTimeline({
      sourceTimelineId: 'public',
      splitTimelineId: splitId,
      contract: { source: 'direct', path: '/api/v1/timelines/direct', params: {} },
      query: createSeekQuery({
        kind: SEEK_KIND.STATUS,
        source: 'direct',
        target: { id: '5' },
      }),
    }));

    expect(result.outcome).toBe('unsupported');
    expect(mockPost).not.toHaveBeenCalled();
    expect(store.getState().getIn(['timelines', splitId, 'items'])).toEqual(before);
  });

  it('posts the seek and swaps the window only after the anchor page resolves', async () => {
    const store = storeWithSplit();
    const calls = [];
    mockPost.mockImplementation(() => Promise.resolve({ data: resolvedBody }));
    mockGet.mockImplementation((path, config) => {
      if (path === '/api/v1/statuses/9007199254740993') {
        return Promise.resolve({ status: 200, data: { id: '9007199254740993' } });
      }

      const params = config && config.params || {};

      return Promise.resolve({
        status: 200,
        data: [{ id: params.min_id ? '9007199254740994' : '9007199254740992' }],
      });
    });

    const result = await store.dispatch(seekWindowedTimeline({
      sourceTimelineId: 'public',
      splitTimelineId: splitId,
      contract,
      query: createSeekQuery({
        kind: SEEK_KIND.STATUS,
        source: 'public',
        target: { id: '9007199254740993', text: 'do not send' },
      }),
    }));

    expect(result.outcome).toBe('unsupported');
    expect(result.reason).toBe('search_text_not_accepted');
    expect(mockPost).not.toHaveBeenCalled();
    expect(calls).toEqual([]);

    const moved = await store.dispatch(seekWindowedTimeline({
      sourceTimelineId: 'public',
      splitTimelineId: splitId,
      contract,
      query: createSeekQuery({
        kind: SEEK_KIND.STATUS,
        source: 'public',
        target: { id: '9007199254740993' },
      }),
    }));

    expect(mockPost).toHaveBeenCalledWith('/api/v1/timelines/seek', expect.objectContaining({
      source: 'public',
      kind: 'status',
      seek_target: { id: '9007199254740993' },
    }), expect.any(Object));
    expect(String(mockPost.mock.calls[0][0])).not.toContain('9007199254740993');
    expect(moved.anchorId).toBe('9007199254740993');
    expect(moved.scroll.pending).toBe(true);
    expect(moved.scroll.scrolled).toBe(false);
    expect(calls).toEqual([]);
    expect(store.getState().getIn(['timelines', splitId, 'seek', 'scrollStatus'])).toBe('pending');
    expect(store.getState().getIn(['timelines', splitId, 'items']).toArray()).toEqual([
      '9007199254740994',
      '9007199254740993',
      '9007199254740992',
    ]);
    expect(store.getState().getIn(['timelines', 'public', 'items'])).toEqual(ids);
  });

  it('leaves the window in place when resolve is outside the redis range', async () => {
    const store = storeWithSplit();
    const before = store.getState().getIn(['timelines', splitId, 'items']);
    mockPost.mockImplementation(() => Promise.resolve({
      data: {
        version: 1,
        outcome: 'unavailable',
        capability: 'approximate',
        limitations: ['retention_2000'],
        reason: 'outside_retained_range',
      },
    }));

    const result = await store.dispatch(seekWindowedTimeline({
      sourceTimelineId: 'public',
      splitTimelineId: splitId,
      contract,
      query: createSeekQuery({ kind: SEEK_KIND.STATUS, source: 'public', target: { id: '15' } }),
    }));

    expect(result.outcome).toBe('unavailable');
    expect(result.reason).toBe('outside_retained_range');
    expect(mockGet).not.toHaveBeenCalled();
    expect(store.getState().getIn(['timelines', splitId, 'items'])).toEqual(before);
    expect(store.getState().getIn(['timelines', splitId, 'window', 'seeking'])).toBe(false);
    expect(store.getState().getIn(['timelines', splitId, 'window', 'anchorId'])).toBe(anchor);
  });

  it('leaves scroll pending after the commit so the list can move once it has rendered', async () => {
    const store = storeWithSplit();
    mockPost.mockImplementation(() => Promise.resolve({ data: resolvedBody }));
    mockGet.mockImplementation((path) => {
      if (String(path).includes('/api/v1/statuses/')) {
        return Promise.resolve({ status: 200, data: { id: '9007199254740993' } });
      }

      return Promise.resolve({ status: 206, data: [] });
    });

    const result = await store.dispatch(seekWindowedTimeline({
      sourceTimelineId: 'public',
      splitTimelineId: splitId,
      contract,
      query: createSeekQuery({ kind: SEEK_KIND.STATUS, source: 'public', target: { id: '9007199254740993' } }),
    }));

    expect(result.scroll.pending).toBe(true);
    expect(result.scroll.scrolled).toBe(false);
    expect(store.getState().getIn(['timelines', splitId, 'items']).toArray()).toEqual(['9007199254740993']);
    expect(store.getState().getIn(['timelines', splitId, 'window', 'older', 'status'])).toBe('paused');
    expect(store.getState().getIn(['timelines', splitId, 'seek', 'scrollStatus'])).toBe('pending');
    expect(store.getState().getIn(['timelines', splitId, 'seek', 'scrollReason'])).toBeNull();
  });

  it('rejects an anchor newer than the split boundary without replacing the window', async () => {
    const state = ImmutableMap({
      timelines: ImmutableMap({
        public: ImmutableMap({
          unread: 0,
          online: true,
          top: true,
          isLoading: false,
          hasMore: true,
          pendingItems: ImmutableList(['500']),
          items: ImmutableList(['300', '200', '100']),
        }),
      }),
    });
    const store = createStore(root, state, applyMiddleware(thunk));

    store.dispatch({
      type: TIMELINE_SPLIT_CREATE,
      sourceTimeline: 'public',
      splitTimeline: splitId,
      anchorId: '200',
    });

    const before = store.getState().getIn(['timelines', splitId, 'items']);
    mockPost.mockImplementation(() => Promise.resolve({
      data: {
        version: 1,
        outcome: 'resolved',
        capability: 'supported',
        precision: 'exact',
        anchor_id: '400',
        display_row_id: '400',
        limitations: [],
      },
    }));

    const result = await store.dispatch(seekWindowedTimeline({
      sourceTimelineId: 'public',
      splitTimelineId: splitId,
      contract,
      query: createSeekQuery({ kind: SEEK_KIND.STATUS, source: 'public', target: { id: '400' } }),
    }));

    expect(result.outcome).toBe('unavailable');
    expect(result.reason).toBe('newer_than_split_boundary');
    expect(result.limitations).toContain('live_side');
    expect(mockGet).not.toHaveBeenCalled();
    expect(store.getState().getIn(['timelines', splitId, 'items'])).toEqual(before);
    expect(store.getState().getIn(['timelines', splitId, 'window', 'seeking'])).toBe(false);
    expect(store.getState().getIn(['timelines', splitId, 'window', 'anchorId'])).toBe('200');
    expect(store.getState().getIn(['timelines', splitId, 'seek', 'phase'])).toBe('unavailable');
    expect(store.getState().getIn(['timelines', 'public', 'pendingItems'])).toEqual(ImmutableList(['500']));
    expect(store.getState().getIn(['timelines', 'public', 'items'])).toEqual(ImmutableList(['300', '200', '100']));
  });

  it('discards a slow resolve after the split closes', async () => {
    const store = storeWithSplit();
    let resolvePost;
    mockPost.mockImplementation(() => new Promise(resolve => {
      resolvePost = resolve;
    }));

    const pending = store.dispatch(seekWindowedTimeline({
      sourceTimelineId: 'public',
      splitTimelineId: splitId,
      contract,
      query: createSeekQuery({ kind: SEEK_KIND.STATUS, source: 'public', target: { id: '15' } }),
    }));

    store.dispatch({
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'public',
      splitTimeline: splitId,
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop: true,
    });

    resolvePost({ data: resolvedBody });
    const result = await pending;

    expect(result.outcome).toBe('stale');
    expect(store.getState().get(splitId)).toBeUndefined();
    expect(mockGet).not.toHaveBeenCalled();
  });

  it('keeps the previous window when the neighborhood request fails', async () => {
    const store = storeWithSplit();
    const before = store.getState().getIn(['timelines', splitId, 'items']);
    mockPost.mockImplementation(() => Promise.resolve({ data: resolvedBody }));
    mockGet.mockImplementation(() => Promise.reject(Object.assign(new Error('offline'), { response: { status: 500 } })));

    const result = await store.dispatch(seekWindowedTimeline({
      sourceTimelineId: 'public',
      splitTimelineId: splitId,
      contract,
      query: createSeekQuery({ kind: SEEK_KIND.DATE, source: 'public', target: { at: '2024-01-01T00:00:00Z' } }),
    }));

    expect(result.outcome).toBe('unavailable');
    expect(result.reason).toBe('network');
    expect(store.getState().getIn(['timelines', splitId, 'items'])).toEqual(before);
    expect(store.getState().getIn(['timelines', splitId, 'window', 'anchorId'])).toBe(anchor);
  });
});
