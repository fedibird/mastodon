import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import timelines from '../../reducers/timelines';
import { TIMELINE_SPLIT_CREATE, TIMELINE_SPLIT_DESTROY } from '../timelines';
import { expandWindowedHistory } from '../windowed_history';

const mockGet = jest.fn();

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: mockGet })),
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
  fetchRelationshipsFromStatus: () => ({ type: 'REL_STATUS' }),
}));

const splitId = 'home:split:session';
const historyIds = Array.from({ length: 300 }, (_, index) => String(3000 - index).padStart(6, '0'));

const root = (state = ImmutableMap(), action) => state.set('timelines', timelines(state.get('timelines'), action));

const storeWithSplit = () => {
  const state = ImmutableMap({
    timelines: ImmutableMap({
      home: ImmutableMap({
        unread: 0,
        online: true,
        top: true,
        isLoading: false,
        hasMore: true,
        pendingItems: ImmutableList(['0003040']),
        items: ImmutableList(historyIds),
      }),
    }),
  });
  const store = createStore(root, state, applyMiddleware(thunk));

  store.dispatch({
    type: TIMELINE_SPLIT_CREATE,
    sourceTimeline: 'home',
    splitTimeline: splitId,
    anchorId: historyIds[180],
  });

  return store;
};

describe('expandWindowedHistory', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockGet.mockImplementation(() => new Promise(() => {}));
  });

  it('loads newer history with min_id and the source filters, not since_id or a link header', () => {
    const store = storeWithSplit();

    store.dispatch(expandWindowedHistory({
      sourceTimelineId: 'home',
      splitTimelineId: splitId,
      contract: {
        source: 'hashtag',
        capability: 'database',
        path: '/api/v1/timelines/tag/news',
        params: { any: ['fedibird'], all: ['window'], none: ['bot'] },
      },
      direction: 'newer',
    }));

    expect(mockGet).toHaveBeenCalledTimes(1);
    const [path, options] = mockGet.mock.calls[0];

    expect(path).toBe('/api/v1/timelines/tag/news');
    expect(options.params.min_id).toBe(store.getState().getIn(['timelines', splitId, 'window', 'newestId']));
    expect(options.params.max_id).toBeUndefined();
    expect(options.params.since_id).toBeUndefined();
    expect(options.params.any).toEqual(['fedibird']);
    expect(options.params.all).toEqual(['window']);
    expect(options.params.none).toEqual(['bot']);
    expect(store.getState().getIn(['timelines', splitId, 'window', 'newer', 'status'])).toBe('loading');
    expect(store.getState().getIn(['timelines', splitId, 'window', 'older', 'status'])).not.toBe('loading');
    expect(store.getState().getIn(['timelines', 'home', 'isLoading'])).not.toBe(true);
  });

  it('does not resurrect history after the split is destroyed', async () => {
    let resolveGet;
    mockGet.mockImplementation(() => new Promise(resolve => {
      resolveGet = resolve;
    }));
    const store = storeWithSplit();
    const pending = store.dispatch(expandWindowedHistory({
      sourceTimelineId: 'home',
      splitTimelineId: splitId,
      contract: {
        source: 'home',
        capability: 'redis',
        path: '/api/v1/timelines/home',
        params: { visibilities: ['public', 'unlisted'] },
      },
      direction: 'older',
      gapCursor: '20',
    }));

    expect(mockGet.mock.calls[0][1].params.max_id).toBe(store.getState().getIn(['timelines', splitId, 'window', 'oldestId']));
    expect(mockGet.mock.calls[0][1].params.visibilities).toEqual(['public', 'unlisted']);
    expect(mockGet.mock.calls[0][1].params.since_id).toBeUndefined();

    store.dispatch({
      type: TIMELINE_SPLIT_DESTROY,
      sourceTimeline: 'home',
      splitTimeline: splitId,
      keep: 'history',
    });
    resolveGet({ status: 200, data: [{ id: '9' }, { id: '8' }] });
    await pending;

    expect(store.getState().get('timelines').has(splitId)).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'items'])).toEqual(ImmutableList(historyIds));
    expect(store.getState().getIn(['timelines', 'home', 'pendingItems'])).toEqual(ImmutableList(['0003040']));
  });
});
