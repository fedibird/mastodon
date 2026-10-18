import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import { accountContextTarget, reblogWrapperTarget } from '../../account_context/target';
import accountContextViews from '../../reducers/account_context_views';
import timelines from '../../reducers/timelines';
import { accountContextHostId } from '../../timeline_seek/account_context';
import { seekSourceKey } from '../../timeline_seek/query';
import { accountHistoryContract } from '../../windowed_history/sources';
import { accountContextFilters } from '../../timeline_seek/account_context';
import { closeAccountContext, lookupReblogWrapper, openAccountContext } from '../account_context_view';

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
const quotedId = '9007199254740888';
const profileId = 'account:42';
const splitHost = 'home:split:column:session';

const root = (state = ImmutableMap(), action) => state
  .set('timelines', timelines(state.get('timelines'), action))
  .set('accountContextViews', accountContextViews(state.get('accountContextViews'), action));

const storeWithProfile = () => createStore(root, ImmutableMap({
  timelines: ImmutableMap({
    [profileId]: ImmutableMap({
      unread: 1,
      online: true,
      top: true,
      isLoading: false,
      hasMore: true,
      pendingItems: ImmutableList(['800']),
      items: ImmutableList(['100', '90']),
    }),
  }),
}), applyMiddleware(thunk));

const resolvedBody = (id) => ({
  version: 1,
  outcome: 'resolved',
  capability: 'supported',
  precision: 'exact',
  anchor_id: id,
  display_row_id: id,
  limitations: [],
});

const idAt = (offset) => String(9007199254740000 + offset);

const page = (path, config) => {
  if (/^\/api\/v1\/statuses\/[^/]+$/.test(String(path))) {
    const id = String(path).split('/').pop();

    return Promise.resolve({ status: 200, data: { id, reblog: null } });
  }

  const params = config && config.params || {};

  return Promise.resolve({
    status: 200,
    data: Array.from({ length: 40 }, (_, index) => ({ id: idAt((params.min_id ? 1100 : 900) + index) })),
  });
};

const quoteStatus = fromJS({
  id: anchor,
  account: { id: '42' },
  in_reply_to_id: '11',
  quote: { id: quotedId, account: { id: '9' } },
});

const boostStatus = fromJS({
  id: anchor,
  account: { id: '42' },
  reblog: { id: '9007199254740991', account: { id: '7' } },
});

describe('openAccountContext', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPost.mockImplementation((_path, body) => Promise.resolve({
      data: resolvedBody(body.seek_target.id),
    }));
    mockGet.mockImplementation(page);
  });

  it('seeks the quoting status and includes replies without touching the profile timeline', async () => {
    const store = storeWithProfile();
    const target = accountContextTarget({ kind: 'quote', status: quoteStatus });
    const result = await store.dispatch(openAccountContext({
      hostTimelineId: splitHost,
      target,
    }));
    const timelineId = accountContextHostId(splitHost);

    expect(target.statusId).toBe(anchor);
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
    expect(result.opened).toBe(true);
    expect(store.getState().getIn(['timelines', timelineId, 'items']).toArray()).toContain(anchor);
    expect(store.getState().getIn(['timelines', timelineId, 'contextHost'])).toBe(true);
    expect(store.getState().getIn(['timelines', profileId, 'items']).toArray()).toEqual(['100', '90']);
    expect(store.getState().getIn(['timelines', profileId, 'pendingItems']).toArray()).toEqual(['800']);
    expect(store.getState().getIn(['accountContextViews', 'sessions', splitHost, 'kind'])).toBe('quote');
  });

  it('seeks a boost wrapper with reblogs included and keeps a second column separate', async () => {
    const store = storeWithProfile();
    const otherHost = 'column:other';
    const boost = accountContextTarget({ kind: 'boost', status: boostStatus });
    const other = accountContextTarget({
      kind: 'quote',
      status: quoteStatus.set('id', '9007199254740994').setIn(['account', 'id'], '42'),
    });

    await store.dispatch(openAccountContext({ hostTimelineId: splitHost, target: boost }));
    await store.dispatch(openAccountContext({ hostTimelineId: otherHost, target: other }));

    const boostContract = accountHistoryContract('42', accountContextFilters({ reblog: true }));
    const quoteContract = accountHistoryContract('42', accountContextFilters({ reply: true }));

    expect(mockPost).toHaveBeenCalledWith('/api/v1/timelines/seek', expect.objectContaining({
      context: expect.objectContaining({
        exclude_replies: true,
        exclude_reblogs: false,
      }),
      seek_target: { id: anchor },
    }), expect.any(Object));
    expect(store.getState().getIn(['timelines', accountContextHostId(splitHost), 'contextSource'])).toBe(seekSourceKey(boostContract));
    expect(store.getState().getIn(['timelines', accountContextHostId(otherHost), 'contextSource'])).toBe(seekSourceKey(quoteContract));
    expect(store.getState().getIn(['accountContextViews', 'order']).toArray()).toEqual([splitHost, otherHost]);

    store.dispatch(closeAccountContext(splitHost));

    expect(store.getState().get('timelines').has(accountContextHostId(splitHost))).toBe(false);
    expect(store.getState().get('timelines').has(accountContextHostId(otherHost))).toBe(true);
    expect(store.getState().getIn(['timelines', profileId, 'items']).toArray()).toEqual(['100', '90']);
    expect(store.getState().getIn(['accountContextViews', 'order']).toArray()).toEqual([otherHost]);
  });

  it('does not open a context from an unresolved booster lookup', async () => {
    const store = storeWithProfile();

    mockGet.mockImplementation((path) => {
      if (String(path).indexOf('/reblog_wrapper') !== -1) {
        return Promise.resolve({ data: { state: 'unknown', reason: 'ambiguous', id: null, account_id: '42' } });
      }

      return page(path);
    });

    const resolution = await store.dispatch(lookupReblogWrapper({
      statusId: '9007199254740991',
      accountId: '42',
    }));
    const target = reblogWrapperTarget({
      accountId: '42',
      originalStatusId: '9007199254740991',
      resolution,
    });
    const opened = await store.dispatch(openAccountContext({
      hostTimelineId: 'reblogs:route:9007199254740991',
      target,
    }));

    expect(target.available).toBe(false);
    expect(target.reason).toBe('ambiguous');
    expect(target.statusId).toBeNull();
    expect(opened.opened).toBe(false);
    expect(mockPost).not.toHaveBeenCalled();
    expect(store.getState().getIn(['timelines', profileId, 'items']).toArray()).toEqual(['100', '90']);
  });
});
