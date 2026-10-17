import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import timelines from '../../reducers/timelines';
import { homeHistoryContract } from '../../windowed_history/sources';
import { TIMELINE_SPLIT_CREATE } from '../timelines';
import { cancelHistoryResume, captureHistoryPosition, resumeHistoryPosition } from '../timeline_position';
import { historySourceIdentity, historyViewIdentity } from '../../timeline_position/identity';
import { resetPositionRegistry } from '../../timeline_position/session';
import { bindHistorySurface, resetHistorySurfaces } from '../../timeline_position/surface';
import { WINDOW_SEEK_COMMIT } from '../../timeline_seek/constants';

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

const splitId = 'home:split:column-a:session-1';
const contract = homeHistoryContract(['public']);
const source = historySourceIdentity('home', contract);
const view = historyViewIdentity({
  columnId: 'column-a',
  sourceTimelineId: 'home',
  locationKey: 'entry-a',
});

const anchor = (statusId) => ({
  version: 1,
  statusId,
  displayRowId: statusId,
  offsetPx: 16,
  alignment: 'top',
  capturedAt: '2026-10-17T00:00:00.000Z',
});

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
        pendingItems: ImmutableList(),
        items: ImmutableList(['300', '200', '100']),
      }),
    }),
  });
  const store = createStore(root, state, applyMiddleware(thunk));

  store.dispatch({
    type: TIMELINE_SPLIT_CREATE,
    sourceTimeline: 'home',
    splitTimeline: splitId,
    anchorId: '200',
  });

  return store;
};

const remember = (statusId) => captureHistoryPosition({
  accountId: '1',
  source,
  view,
  anchor: anchor(statusId),
  layout: 'single',
  routeEntryKey: 'entry-a',
  sync: true,
});

const resume = (store) => store.dispatch(resumeHistoryPosition({
  accountId: '1',
  sourceTimelineId: 'home',
  splitTimelineId: splitId,
  contract,
  source,
  view,
  locationKey: 'entry-b',
  historyAction: 'PUSH',
  explicit: true,
  multiColumn: false,
}));

describe('resumeHistoryPosition', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    resetPositionRegistry();
    resetHistorySurfaces();
  });

  it('scrolls inside the current window and does not seek', async () => {
    const store = storeWithSplit();
    const before = store.getState().getIn(['timelines', splitId, 'items']);
    const restore = jest.fn(() => ({ ok: true, reason: 'loaded' }));

    bindHistorySurface(splitId, { restore, capture: () => null });
    remember('100');

    const result = await resume(store);

    expect(result).toMatchObject({ ok: true, mode: 'scroll', preserved: true });
    expect(restore).toHaveBeenCalledWith(expect.objectContaining({ statusId: '100', offsetPx: 16 }), expect.any(Object));
    expect(mockPost).not.toHaveBeenCalled();
    expect(store.getState().getIn(['timelines', splitId, 'items'])).toEqual(before);
    expect(store.getState().getIn(['timelines', splitId, 'historyResume', 'phase'])).toBe('restored');
  });

  it('does not move the window when seek cannot find the row', async () => {
    const store = storeWithSplit();
    const before = store.getState().getIn(['timelines', splitId, 'items']);

    mockPost.mockRejectedValue({ response: { status: 404 } });
    remember('9007199254740993');

    const result = await resume(store);

    expect(result).toMatchObject({ ok: false, reason: 'not_found', nondestructive: true, preserved: true });
    expect(store.getState().getIn(['timelines', splitId, 'items'])).toEqual(before);
    expect(store.getState().getIn(['timelines', splitId, 'historyResume', 'phase'])).toBe('failed');
    expect(store.getState().getIn(['timelines', splitId, 'historyResume', 'reason'])).toBe('not_found');
  });

  it('marks seek resolved before the post-render scroll settles', async () => {
    const store = storeWithSplit();

    mockPost.mockResolvedValue({
      data: {
        version: 1,
        outcome: 'resolved',
        capability: 'approximate',
        precision: 'exact',
        anchor_id: '50',
        display_row_id: '50',
        limitations: [],
      },
    });
    mockGet.mockImplementation((path) => {
      if (path === '/api/v1/statuses/50') {
        return Promise.resolve({ data: { id: '50' } });
      }

      return Promise.resolve({
        status: 200,
        data: [{ id: '40' }],
      });
    });
    remember('50');

    const result = await resume(store);
    const resumeState = store.getState().getIn(['timelines', splitId, 'historyResume']);

    expect(result).toMatchObject({ ok: true, reason: 'seek_resolved', scrollPending: true, preserved: true });
    expect(resumeState.get('phase')).toBe('scroll_pending');
    expect(resumeState.get('reason')).toBe('seek_resolved');
    expect(store.getState().getIn(['timelines', splitId, 'seek', 'scrollStatus'])).toBe('pending');
    expect(store.getState().getIn(['timelines', splitId, 'items']).includes('50')).toBe(true);

    store.dispatch({
      type: 'WINDOW_SEEK_SCROLL',
      timeline: splitId,
      sessionId: resumeState.get('seekSessionId'),
      revision: store.getState().getIn(['timelines', splitId, 'seek', 'scrollRevision']),
      scrolled: true,
      reason: 'loaded',
    });

    expect(store.getState().getIn(['timelines', splitId, 'historyResume', 'phase'])).toBe('restored');
    expect(store.getState().getIn(['timelines', splitId, 'seek', 'scrollStatus'])).toBe('loaded');
  });

  it('drops a late seek commit after the reader scrolls', async () => {
    const store = storeWithSplit();
    const before = store.getState().getIn(['timelines', splitId, 'items']);
    let resolvePost;

    mockPost.mockReturnValue(new Promise(resolve => {
      resolvePost = resolve;
    }));
    remember('50');

    const pending = resume(store);
    const requestId = store.getState().getIn(['timelines', splitId, 'historyResume', 'requestId']);
    const seekSessionId = store.getState().getIn(['timelines', splitId, 'historyResume', 'seekSessionId']);

    store.dispatch(cancelHistoryResume({
      splitTimelineId: splitId,
      requestId,
      reason: 'user_scroll',
    }));

    resolvePost({
      data: {
        version: 1,
        outcome: 'resolved',
        capability: 'approximate',
        precision: 'exact',
        anchor_id: '50',
        display_row_id: '50',
        limitations: [],
      },
    });

    const result = await pending;

    expect(result.reason).not.toBe('seek_resolved');
    expect(store.getState().getIn(['timelines', splitId, 'items'])).toEqual(before);
    expect(store.getState().getIn(['timelines', splitId, 'historyResume', 'phase'])).toBe('cancelled');

    store.dispatch({
      type: WINDOW_SEEK_COMMIT,
      timeline: splitId,
      sessionId: seekSessionId,
      source: store.getState().getIn(['timelines', splitId, 'seek', 'source']),
      anchorId: '50',
      newerIds: ['40'],
      olderIds: [],
      limit: 40,
      capability: 'redis',
    });
    expect(store.getState().getIn(['timelines', splitId, 'items'])).toEqual(before);
  });

  it('does not resume on a fresh visit unless asked', async () => {
    const store = storeWithSplit();

    remember('100');

    const result = await store.dispatch(resumeHistoryPosition({
      accountId: '1',
      sourceTimelineId: 'home',
      splitTimelineId: splitId,
      contract,
      source,
      view,
      locationKey: 'entry-b',
      historyAction: 'PUSH',
      explicit: false,
    }));

    expect(result).toMatchObject({ ok: false, reason: 'new_visit', preserved: true });
    expect(mockPost).not.toHaveBeenCalled();
  });
});
