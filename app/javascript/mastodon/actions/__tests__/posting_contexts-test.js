jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import api from '../../api';
import posting_contexts from '../../reducers/posting_contexts';
import { POSTING_CONTEXT_CACHE_TTL, fetchPostingContext } from '../posting_contexts';

const resolvedData = {
  schema_version: 1,
  account_id: '123',
  status: 'resolved',
  context: {
    key: 'builtin:fedibird-group:123',
    source: { id: 'builtin:fedibird-group', revision: 1 },
    managed: { hashtags: [], mentions: [] },
    requirements: { following_accounts: [] },
    constraints: { allowed_visibilities: ['public', 'unlisted'] },
  },
  discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
};

const neutral = (accountId, status, reason) => ({
  schema_version: 1,
  account_id: accountId,
  status,
  reason,
  context: null,
  discovery: { mechanism: null, adapter: null, authority: null },
});

const makeStore = () => createStore(
  combineReducers({ posting_contexts }),
  applyMiddleware(thunk),
);

describe('fetchPostingContext', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('requests the Fedibird discovery endpoint once per uncached account', async () => {
    const get = jest.fn()
      .mockResolvedValueOnce({ data: resolvedData })
      .mockResolvedValueOnce({ data: neutral('456', 'unsupported', 'no_supported_adapter') })
      .mockResolvedValueOnce({ data: neutral('789', 'not_applicable', 'not_group') });
    api.mockReturnValue({ get });
    const store = makeStore();

    await store.dispatch(fetchPostingContext('123'));
    await store.dispatch(fetchPostingContext('123'));
    await store.dispatch(fetchPostingContext('456'));
    await store.dispatch(fetchPostingContext('456'));
    await store.dispatch(fetchPostingContext('789'));
    await store.dispatch(fetchPostingContext('789'));

    expect(get).toHaveBeenCalledTimes(3);
    expect(get).toHaveBeenNthCalledWith(1, '/api/v1/fedibird/accounts/123/posting_context');
    expect(get).toHaveBeenNthCalledWith(2, '/api/v1/fedibird/accounts/456/posting_context');
    expect(get).toHaveBeenNthCalledWith(3, '/api/v1/fedibird/accounts/789/posting_context');
    expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('resolved');
    expect(store.getState().getIn(['posting_contexts', '456', 'status'])).toEqual('unsupported');
    expect(store.getState().getIn(['posting_contexts', '789', 'status'])).toEqual('not_applicable');
  });

  it('does not start another request while one is loading', () => {
    let resolveGet;
    const get = jest.fn(() => new Promise(resolve => {
      resolveGet = resolve;
    }));
    api.mockReturnValue({ get });
    const store = makeStore();

    const first = store.dispatch(fetchPostingContext('123'));
    const second = store.dispatch(fetchPostingContext('123', { force: true }));

    expect(get).toHaveBeenCalledTimes(1);
    expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('loading');

    resolveGet({ data: resolvedData });
    return Promise.all([first, second]);
  });

  it('retries after an error and marks the failure to skip alerts', async () => {
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce({ data: resolvedData });
    api.mockReturnValue({ get });
    const actions = [];
    const recorder = () => next => action => {
      actions.push(action);
      return next(action);
    };
    const store = createStore(
      combineReducers({ posting_contexts }),
      applyMiddleware(thunk, recorder),
    );

    await store.dispatch(fetchPostingContext('123'));

    expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('error');
    expect(store.getState().getIn(['posting_contexts', '123', 'context'])).toBeNull();
    expect(actions.find(action => action.type === 'POSTING_CONTEXT_FETCH_FAIL').skipAlert).toBe(true);

    await store.dispatch(fetchPostingContext('123'));

    expect(get).toHaveBeenCalledTimes(2);
    expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('resolved');
  });

  describe('cache TTL', () => {
    const start = 1_700_000_000_000;

    beforeEach(() => {
      jest.spyOn(Date, 'now').mockReturnValue(start);
    });

    afterEach(() => {
      jest.restoreAllMocks();
    });

    it('skips fresh success results and refetches them after the TTL', async () => {
      const get = jest.fn()
        .mockResolvedValueOnce({ data: resolvedData })
        .mockResolvedValueOnce({ data: neutral('456', 'unsupported', 'no_supported_adapter') })
        .mockResolvedValueOnce({ data: neutral('789', 'not_applicable', 'not_group') })
        .mockResolvedValueOnce({ data: resolvedData })
        .mockResolvedValueOnce({ data: neutral('456', 'unsupported', 'no_supported_adapter') })
        .mockResolvedValueOnce({ data: neutral('789', 'not_applicable', 'not_group') });
      api.mockReturnValue({ get });
      const store = makeStore();

      await store.dispatch(fetchPostingContext('123'));
      await store.dispatch(fetchPostingContext('456'));
      await store.dispatch(fetchPostingContext('789'));
      expect(get).toHaveBeenCalledTimes(3);
      expect(store.getState().getIn(['posting_contexts', '123', 'receivedAt'])).toEqual(start);
      expect(store.getState().getIn(['posting_contexts', '123', 'viewerEvidence'])).toBeNull();

      Date.now.mockReturnValue(start + POSTING_CONTEXT_CACHE_TTL - 1);
      await store.dispatch(fetchPostingContext('123'));
      await store.dispatch(fetchPostingContext('456'));
      await store.dispatch(fetchPostingContext('789'));
      expect(get).toHaveBeenCalledTimes(3);

      Date.now.mockReturnValue(start + POSTING_CONTEXT_CACHE_TTL);
      await store.dispatch(fetchPostingContext('123'));
      await store.dispatch(fetchPostingContext('456'));
      await store.dispatch(fetchPostingContext('789'));
      expect(get).toHaveBeenCalledTimes(6);
      expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('resolved');
      expect(store.getState().getIn(['posting_contexts', '456', 'status'])).toEqual('unsupported');
      expect(store.getState().getIn(['posting_contexts', '789', 'status'])).toEqual('not_applicable');
      expect(store.getState().getIn(['posting_contexts', '123', 'receivedAt'])).toEqual(start + POSTING_CONTEXT_CACHE_TTL);
    });

    it('refetches a fresh resolved result when force is set', async () => {
      const get = jest.fn()
        .mockResolvedValueOnce({ data: resolvedData })
        .mockResolvedValueOnce({ data: resolvedData });
      api.mockReturnValue({ get });
      const store = makeStore();

      await store.dispatch(fetchPostingContext('123'));
      await store.dispatch(fetchPostingContext('123', { force: true }));

      expect(get).toHaveBeenCalledTimes(2);
      expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('resolved');
    });

    it('keeps the resolved context while a stale result refreshes and dedupes that refresh', async () => {
      let resolveGet;
      const get = jest.fn()
        .mockResolvedValueOnce({ data: resolvedData })
        .mockImplementationOnce(() => new Promise(resolve => {
          resolveGet = resolve;
        }));
      api.mockReturnValue({ get });
      const store = makeStore();

      await store.dispatch(fetchPostingContext('123'));
      Date.now.mockReturnValue(start + POSTING_CONTEXT_CACHE_TTL);
      const pending = store.dispatch(fetchPostingContext('123'));
      const again = store.dispatch(fetchPostingContext('123', { force: true }));

      expect(get).toHaveBeenCalledTimes(2);
      expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('resolved');
      expect(store.getState().getIn(['posting_contexts', '123', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
      expect(store.getState().getIn(['posting_contexts', '123', 'refreshing'])).toBe(true);

      resolveGet({
        data: {
          ...resolvedData,
          viewer_evidence: {
            affiliations: {
              source: 'fep-5219-affiliations',
              snapshot_status: 'fresh',
              fetched_at: '2026-10-07T01:23:45Z',
              relationships: [],
            },
            permissions: {
              create: {
                status: 'allowed',
                source: 'fep-5219',
                via_relationship: 'none',
                authority: 'protocol',
              },
            },
          },
        },
      });
      await Promise.all([pending, again]);

      expect(store.getState().getIn(['posting_contexts', '123', 'refreshing'])).toBe(false);
      expect(store.getState().getIn(['posting_contexts', '123', 'refreshError'])).toBeNull();
      expect(store.getState().getIn(['posting_contexts', '123', 'viewerEvidence', 'permissions', 'create', 'status'])).toEqual('allowed');
      expect(store.getState().getIn(['posting_contexts', '123', 'viewerEvidence', 'permissions', 'create', 'viaRelationship'])).toEqual('none');
      expect(store.getState().getIn(['posting_contexts', '123', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
    });

    it('keeps the context after a refresh failure and allows another attempt', async () => {
      const get = jest.fn()
        .mockResolvedValueOnce({ data: resolvedData })
        .mockRejectedValueOnce(new Error('offline'))
        .mockResolvedValueOnce({ data: resolvedData });
      api.mockReturnValue({ get });
      const store = makeStore();

      await store.dispatch(fetchPostingContext('123'));
      Date.now.mockReturnValue(start + POSTING_CONTEXT_CACHE_TTL);
      await store.dispatch(fetchPostingContext('123'));

      expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('resolved');
      expect(store.getState().getIn(['posting_contexts', '123', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
      expect(store.getState().getIn(['posting_contexts', '123', 'refreshing'])).toBe(false);
      expect(store.getState().getIn(['posting_contexts', '123', 'refreshError'])).toBe(true);
      expect(store.getState().getIn(['posting_contexts', '123', 'receivedAt'])).toEqual(start);

      Date.now.mockReturnValue(start + 1);
      await store.dispatch(fetchPostingContext('123'));

      expect(get).toHaveBeenCalledTimes(3);
      expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('resolved');
      expect(store.getState().getIn(['posting_contexts', '123', 'refreshError'])).toBeNull();
      expect(store.getState().getIn(['posting_contexts', '123', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
    });

    it('discards a retained context when the next success is unsupported', async () => {
      const get = jest.fn()
        .mockResolvedValueOnce({ data: resolvedData })
        .mockResolvedValueOnce({ data: neutral('123', 'unsupported', 'no_supported_adapter') });
      api.mockReturnValue({ get });
      const store = makeStore();

      await store.dispatch(fetchPostingContext('123'));
      Date.now.mockReturnValue(start + POSTING_CONTEXT_CACHE_TTL);
      await store.dispatch(fetchPostingContext('123'));

      expect(store.getState().getIn(['posting_contexts', '123', 'status'])).toEqual('unsupported');
      expect(store.getState().getIn(['posting_contexts', '123', 'context'])).toBeNull();
      expect(store.getState().getIn(['posting_contexts', '123', 'refreshing'])).toBe(false);
    });
  });
});
