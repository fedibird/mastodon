import { fromJS } from 'immutable';

const flags = {
  isAdministrator: false,
  new_features_policy: 'default',
};

const mockPut = jest.fn(() => Promise.resolve({}));
const mockGet = jest.fn(() => Promise.resolve({ data: { accounts: [], hashtags: [] } }));

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../initial_state', () => ({
  get isAdministrator () {
    return flags.isAdministrator;
  },
  get new_features_policy () {
    return flags.new_features_policy;
  },
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: () => ({
    put: (...args) => mockPut(...args),
    get: (...args) => mockGet(...args),
  }),
}));

import { createMix, deleteMix, searchMixSources, updateMix } from '../mixes';

const home = { type: 'home', params: {} };
const remote = { type: 'remote', params: {} };

const run = (action, state) => {
  const current = { state };

  const dispatch = (next) => {
    if (typeof next === 'function') {
      return next(dispatch, () => current.state);
    }

    if (next.type === 'MIXES_REPLACE') {
      current.state = current.state.setIn(['settings', 'mixes'], next.mixes).setIn(['settings', 'saved'], false);
    }

    return next;
  };

  return action(dispatch, () => current.state);
};

describe('mix setting actions', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    flags.isAdministrator = false;
    flags.new_features_policy = 'default';
    mockPut.mockClear();
    mockGet.mockClear();
  });

  afterEach(() => {
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
  });

  it('refuses to save a mix unless the viewer is an administrator or beta tester', () => {
    const state = fromJS({ settings: { mixes: [], saved: true } });
    const refused = run(createMix({ title: 'Desk', sources: [home, remote] }), state);

    expect(refused).toEqual({ ok: false, errors: ['unavailable'] });
    expect(mockPut).not.toHaveBeenCalled();

    flags.new_features_policy = 'tester';
    const saved = run(createMix({ title: 'Desk', sources: [home, remote] }), state);

    expect(saved.ok).toBe(true);
    expect(mockPut).toHaveBeenCalledWith('/api/web/settings', expect.any(Object));
    const payload = mockPut.mock.calls[0][1].data;

    expect(payload.mixes).toHaveLength(1);
    expect(payload.mixes[0].title).toBe('Desk');
    expect(JSON.stringify(payload.mixes)).not.toContain('content');
    expect(payload.saved).toBeUndefined();
  });

  it('updates and deletes definitions without keeping removed mixes', () => {
    flags.isAdministrator = true;
    const created = { id: 'mix-1', version: 1, title: 'Desk', sources: [home, remote] };
    let state = fromJS({ settings: { mixes: [created], saved: true } });
    const replaced = [];
    const dispatch = (next) => {
      if (typeof next === 'function') {
        return next(dispatch, () => state);
      }

      if (next.type === 'MIXES_REPLACE') {
        replaced.push(next.mixes.toJS());
        state = state.setIn(['settings', 'mixes'], next.mixes);
      }

      return next;
    };

    const updated = updateMix('mix-1', {
      title: 'Night',
      sources: [home, { type: 'list', id: '3', params: {} }],
    })(dispatch, () => state);

    expect(updated.ok).toBe(true);
    expect(updated.mix.id).toBe('mix-1');
    expect(updated.mix.title).toBe('Night');
    expect(replaced[replaced.length - 1][0].sources[1]).toEqual({ type: 'list', id: '3', params: {} });

    const removed = deleteMix('mix-1')(dispatch, () => state);

    expect(removed).toEqual({ ok: true });
    expect(replaced[replaced.length - 1]).toEqual([]);
    expect(state.getIn(['settings', 'mixes']).toJS()).toEqual([]);
  });

  it('searches accounts and hashtags through known endpoints', async () => {
    flags.isAdministrator = true;
    mockGet.mockImplementation((path) => {
      if (path === '/api/v2/search') {
        return Promise.resolve({ data: { hashtags: [{ name: 'ruby' }] } });
      }

      return Promise.resolve({
        data: [
          { id: '5', acct: 'ada@example.com', group: false },
          { id: '8', acct: 'news', group: true },
        ],
      });
    });

    const dispatch = (action) => (typeof action === 'function' ? action(dispatch, () => fromJS({})) : action);
    const hashtags = await searchMixSources('hashtag', 'ruby')(dispatch, () => fromJS({}));
    const accounts = await searchMixSources('account', 'ada')(dispatch, () => fromJS({}));
    const groups = await searchMixSources('group', 'news')(dispatch, () => fromJS({}));

    expect(hashtags).toEqual([{ type: 'hashtag', id: 'ruby', title: '#ruby' }]);
    expect(accounts).toEqual([{ type: 'account', id: '5', title: 'ada@example.com' }]);
    expect(groups).toEqual([{ type: 'group', id: '8', title: 'news' }]);
    expect(mockGet).toHaveBeenCalledWith('/api/v2/search', expect.objectContaining({
      params: expect.objectContaining({ type: 'hashtags', q: 'ruby' }),
    }));
    expect(mockGet).toHaveBeenCalledWith('/api/v1/accounts/search', expect.any(Object));
    expect(mockGet.mock.calls.every(call => !String(call[0]).includes('://'))).toBe(true);
  });
});
