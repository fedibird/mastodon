import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import timelines from '../../reducers/timelines';
import { accountContextFilters } from '../../timeline_seek/account_context';
import { SEEK_KIND } from '../../timeline_seek/constants';
import { createSeekQuery } from '../../timeline_seek/query';
import { accountHistoryContract } from '../../windowed_history/sources';
import { expandAccountContext, seekAccountContext, settleAccountContextScroll } from '../account_context_history';
import { seekWindowedTimeline } from '../timeline_seek';

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

const anchor = '9007199254740993';
const profileId = 'account:42';
const splitId = 'home:split:session';
const hostKey = 'column:42:posts';

const root = (state = ImmutableMap(), action) => state.set('timelines', timelines(state.get('timelines'), action));

const storeWithNeighbors = () => {
  const state = ImmutableMap({
    timelines: ImmutableMap({
      [profileId]: ImmutableMap({
        unread: 2,
        online: true,
        top: true,
        isLoading: false,
        hasMore: true,
        pendingItems: ImmutableList(['9007199254740999']),
        items: ImmutableList(['100', '90']),
      }),
      home: ImmutableMap({
        unread: 1,
        online: true,
        top: true,
        isLoading: false,
        hasMore: true,
        pendingItems: ImmutableList(['800']),
        items: ImmutableList(['700', '600']),
        splitTimelineId: splitId,
      }),
      [splitId]: ImmutableMap({
        unread: 0,
        online: false,
        top: false,
        isLoading: false,
        hasMore: true,
        pendingItems: ImmutableList(),
        items: ImmutableList(['700', '600']),
        historyResume: ImmutableMap({ phase: 'armed', mode: 'return' }),
      }),
    }),
  });

  return createStore(root, state, applyMiddleware(thunk));
};

const contract = accountHistoryContract('42', accountContextFilters({ reply: true }));

const resolvedBody = {
  version: 1,
  outcome: 'resolved',
  capability: 'supported',
  precision: 'exact',
  anchor_id: anchor,
  display_row_id: anchor,
  limitations: [],
};

const idAt = (offset) => String(9007199254740000 + offset);

const pageIds = (start) => Array.from({ length: 40 }, (_, index) => idAt(start + index));

const page = (path, config) => {
  if (path === `/api/v1/statuses/${anchor}`) {
    return Promise.resolve({ status: 200, data: { id: anchor, reblog: null } });
  }

  const params = config && config.params || {};

  return Promise.resolve({
    status: 200,
    data: pageIds(params.min_id ? 1100 : 900).map(id => ({ id })),
  });
};

describe('account context history', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPost.mockImplementation(() => Promise.resolve({ data: resolvedBody }));
    mockGet.mockImplementation(page);
  });

  it('seeks a status id, scrolls after render, and pages without touching the profile or another column', async () => {
    const store = storeWithNeighbors();
    const result = await store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: anchor,
    }));

    expect(mockPost).toHaveBeenCalledWith('/api/v1/timelines/seek', expect.objectContaining({
      source: 'account',
      kind: 'status',
      context: expect.objectContaining({
        account_id: '42',
        exclude_replies: false,
        exclude_reblogs: true,
      }),
      seek_target: { id: anchor },
    }), expect.any(Object));
    expect(result.outcome).toBe('resolved');
    expect(result.anchorId).toBe(anchor);
    expect(result.scroll.scrolled).toBe(false);
    const hosted = store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items']).toArray();
    expect(hosted[0]).toBe(idAt(1139));
    expect(hosted).toContain(anchor);
    expect(hosted[hosted.length - 1]).toBe(idAt(900));
    expect(store.getState().getIn(['timelines', profileId, 'items']).toArray()).toEqual(['100', '90']);
    expect(store.getState().getIn(['timelines', profileId, 'pendingItems']).toArray()).toEqual(['9007199254740999']);
    expect(store.getState().getIn(['timelines', profileId, 'splitTimelineId'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', splitId, 'items']).toArray()).toEqual(['700', '600']);
    expect(store.getState().getIn(['timelines', splitId, 'historyResume', 'phase'])).toBe('armed');
    expect(store.getState().getIn(['timelines', 'home', 'pendingItems']).toArray()).toEqual(['800']);

    const loaded = store.dispatch(settleAccountContextScroll({
      hostTimelineId: hostKey,
      renderedIds: ImmutableList(['9007199254740994', anchor, '9007199254740992']),
      articlePresent: true,
      previous: result.previous,
    }));
    expect(loaded).toEqual({ scroll: true, reason: 'loaded', anchorId: anchor });
    expect(store.getState().getIn(['timelines', `account-context:${hostKey}`, 'seek', 'scrollStatus'])).toBe('loaded');

    mockGet.mockClear();
    await store.dispatch(expandAccountContext({
      hostTimelineId: hostKey,
      contract,
      direction: 'older',
    }));
    await store.dispatch(expandAccountContext({
      hostTimelineId: hostKey,
      contract,
      direction: 'newer',
    }));

    const paths = mockGet.mock.calls.map(call => ({ path: call[0], params: call[1].params }));
    expect(paths).toEqual([
      expect.objectContaining({
        path: '/api/v1/accounts/42/statuses',
        params: expect.objectContaining({ max_id: idAt(900), compact: true, exclude_replies: false }),
      }),
      expect.objectContaining({
        path: '/api/v1/accounts/42/statuses',
        params: expect.objectContaining({ min_id: idAt(1139), compact: true, exclude_reblogs: true }),
      }),
    ]);
    expect(store.getState().getIn(['timelines', profileId, 'items']).toArray()).toEqual(['100', '90']);
  });

  it('restores the previous window when the anchor is filtered or not loaded', async () => {
    const store = storeWithNeighbors();
    const first = await store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: anchor,
    }));
    store.dispatch(settleAccountContextScroll({
      hostTimelineId: hostKey,
      renderedIds: ImmutableList([anchor]),
      articlePresent: true,
      previous: first.previous,
    }));
    const kept = store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items']);

    mockPost.mockImplementation(() => Promise.resolve({
      data: { ...resolvedBody, anchor_id: '9007199254740991', display_row_id: '9007199254740991' },
    }));
    mockGet.mockImplementation((path, config) => {
      if (String(path).indexOf('/api/v1/statuses/') === 0) {
        return Promise.resolve({ status: 200, data: { id: '9007199254740991' } });
      }

      const params = config && config.params || {};
      return Promise.resolve({ status: 200, data: [{ id: params.min_id ? '9007199254740995' : '9007199254740990' }] });
    });

    const second = await store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: '9007199254740991',
    }));
    const filtered = store.dispatch(settleAccountContextScroll({
      hostTimelineId: hostKey,
      renderedIds: ImmutableList(['9007199254740995']),
      articlePresent: true,
      previous: second.previous,
    }));

    expect(filtered.reason).toBe('filtered');
    expect(store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items'])).toEqual(kept);

    const moved = await store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: '9007199254740991',
    }));
    const unloaded = store.dispatch(settleAccountContextScroll({
      hostTimelineId: hostKey,
      renderedIds: moved && store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items']),
      articlePresent: false,
      previous: moved.previous,
    }));

    expect(unloaded.reason).toBe('not_loaded');
    expect(store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items'])).toEqual(kept);
    expect(store.getState().getIn(['timelines', splitId, 'historyResume', 'phase'])).toBe('armed');
  });

  it('drops a stale reply when the host closes or the source changes', async () => {
    const store = storeWithNeighbors();
    const resolvers = [];
    mockPost.mockImplementation(() => new Promise(resolve => {
      resolvers.push(resolve);
    }));

    const pending = store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: anchor,
    }));
    const profileBefore = store.getState().getIn(['timelines', profileId, 'items']);
    store.dispatch({ type: 'ACCOUNT_CONTEXT_CLOSE', timeline: `account-context:${hostKey}` });
    resolvers[0]({ data: resolvedBody });
    const closed = await pending;

    expect(closed.outcome).toBe('stale');
    expect(store.getState().get('timelines').has(`account-context:${hostKey}`)).toBe(false);
    expect(store.getState().getIn(['timelines', profileId, 'items'])).toEqual(profileBefore);
    expect(mockGet).not.toHaveBeenCalled();

    const again = store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: anchor,
    }));
    const replacement = store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract: accountHistoryContract('42', accountContextFilters({ reblog: true })),
      statusId: anchor,
    }));
    resolvers[1]({ data: resolvedBody });
    const replaced = await again;
    resolvers[2]({
      data: { version: 1, outcome: 'not_in_source', capability: 'supported', limitations: [] },
    });
    await replacement;

    expect(replaced.outcome).toBe('stale');
    expect(store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items']).size).toBe(0);
    expect(store.getState().getIn(['timelines', profileId, 'pendingItems']).toArray()).toEqual(['9007199254740999']);
  });

  it('does not move the window when the kind is not implemented or the seek fails', async () => {
    const store = storeWithNeighbors();
    const opened = store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: anchor,
    }));
    await opened;
    const items = store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items']);

    const date = await store.dispatch(seekWindowedTimeline({
      sourceTimelineId: `account-context:${hostKey}`,
      splitTimelineId: `account-context:${hostKey}`,
      contract,
      query: createSeekQuery({
        kind: SEEK_KIND.DATE,
        source: 'account',
        target: { at: '2024-01-01T00:00:00Z' },
      }),
    }));

    expect(date.outcome).toBe('unsupported');
    expect(date.reason).toBe('date_seek_not_implemented');
    expect(store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items'])).toEqual(items);

    mockPost.mockImplementation(() => Promise.resolve({
      data: { version: 1, outcome: 'not_in_source', capability: 'supported', limitations: [], reason: null },
    }));
    const missed = await store.dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: '50',
    }));

    expect(missed.outcome).toBe('not_in_source');
    expect(store.getState().getIn(['timelines', `account-context:${hostKey}`, 'items'])).toEqual(items);
    expect(store.getState().getIn(['timelines', splitId, 'items']).toArray()).toEqual(['700', '600']);
  });
});
