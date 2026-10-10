const flags = { isAdministrator: true, new_features_policy: 'default' };

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
    get: (...args) => mockGet(...args),
  }),
  getLinks: (response) => (response && response.links) || { refs: [] },
}));

jest.mock('../importer', () => ({
  importFetchedStatuses: (statuses) => ({ type: 'IMPORT_STATUSES', statuses }),
}));

const mockGet = jest.fn();

import { fromJS } from 'immutable';
import mixTimelines from '../../reducers/mix_timelines';
import { closeMixTimeline, loadMixTimeline, retryMixSource } from '../mix_timelines';
import { MIX_FETCH_BUDGET } from '../../mix/merge';
import { sourceKey } from '../../mix/source';

const mix = fromJS({
  id: 'mix-1',
  version: 1,
  title: 'Desk',
  sources: [
    { type: 'home', params: {} },
    { type: 'list', id: '4', params: {} },
  ],
});

describe('mix timeline loading', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  it('imports statuses without writing the original timeline items', async () => {
    mockGet.mockImplementation((path) => Promise.resolve({
      data: [{ id: path.indexOf('list') === -1 ? '500' : '400', account: '2' }],
      headers: {},
    }));

    let state = fromJS({
      settings: { mixes: [mix] },
      timelines: { home: { items: ['existing'] } },
      mix_timelines: {},
    });
    const dispatched = [];
    const dispatch = (action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => state);
      }

      dispatched.push(action);
      if (action.type && action.type.indexOf('MIX_') === 0) {
        state = state.set('mix_timelines', mixTimelines(state.get('mix_timelines'), action));
      }

      return action;
    };

    await loadMixTimeline('column:one', mix)(dispatch, () => state);

    expect(mockGet).toHaveBeenCalledWith('/api/v1/timelines/home', expect.any(Object));
    expect(mockGet).toHaveBeenCalledWith('/api/v1/timelines/list/4', expect.any(Object));
    expect(dispatched.some(action => action.type === 'IMPORT_STATUSES')).toBe(true);
    expect(dispatched.some(action => String(action.type || '').indexOf('TIMELINE_') === 0)).toBe(false);
    expect(state.getIn(['timelines', 'home', 'items']).toArray()).toEqual(['existing']);
    expect(state.getIn(['mix_timelines', 'column:one', 'sources']).keySeq().size).toBe(2);
  });

  const deferredMix = fromJS({
    id: 'mix-1',
    version: 1,
    title: 'Desk',
    sources: [
      { type: 'public', params: {} },
      { type: 'remote', params: {} },
    ],
  });

  const harness = () => {
    let state = fromJS({
      settings: { mixes: [] },
      timelines: { home: { items: ['existing'] } },
      statuses: {},
      mix_timelines: {},
    });
    const dispatch = (action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => state);
      }

      if (action.type && action.type.indexOf('MIX_') === 0) {
        state = state.set('mix_timelines', mixTimelines(state.get('mix_timelines'), action));
      }

      return action;
    };

    return {
      dispatch,
      getState: () => state,
    };
  };

  const page = (id) => ({ status: 200, data: [{ id, account: '2' }], headers: {} });

  it('discards a late success from the session that was closed', async () => {
    const waiting = [];
    let hold = true;

    mockGet.mockImplementation(() => {
      if (hold) {
        return new Promise(resolve => waiting.push(resolve));
      }

      return Promise.resolve(page('200'));
    });

    const { dispatch, getState } = harness();
    const first = loadMixTimeline('column:one', deferredMix)(dispatch, getState);

    await Promise.resolve();
    expect(waiting.length).toBe(2);
    dispatch(closeMixTimeline('column:one'));
    hold = false;
    await loadMixTimeline('column:one', deferredMix)(dispatch, getState);
    waiting.forEach(resolve => resolve(page('100')));
    await first;

    const ids = getState().getIn(['mix_timelines', 'column:one', 'sources']).valueSeq().flatMap(source => source.get('ids')).toArray();

    expect(ids).toContain('200');
    expect(ids).not.toContain('100');
    expect(getState().getIn(['timelines', 'home', 'items']).toArray()).toEqual(['existing']);
  });

  it('discards a late failure from the session that was closed', async () => {
    const waiting = [];
    let hold = true;

    mockGet.mockImplementation(() => {
      if (hold) {
        return new Promise((resolve, reject) => waiting.push(reject));
      }

      return Promise.resolve(page('200'));
    });

    const { dispatch, getState } = harness();
    const first = loadMixTimeline('column:one', deferredMix)(dispatch, getState);

    await Promise.resolve();
    dispatch(closeMixTimeline('column:one'));
    hold = false;
    await loadMixTimeline('column:one', deferredMix)(dispatch, getState);
    waiting.forEach(reject => reject({ response: { status: 500 } }));
    await first;

    const sources = getState().getIn(['mix_timelines', 'column:one', 'sources']);

    expect(sources.valueSeq().every(source => source.get('error') === null)).toBe(true);
    expect(sources.valueSeq().flatMap(source => source.get('ids')).toArray()).toContain('200');
  });

  const nextLink = (path, maxId) => ({
    refs: [{ rel: 'next', uri: `${window.location.origin}${path}?max_id=${maxId}` }],
  });

  const remoteCall = (call) => !!(call[1] && call[1].params && call[1].params.remote);

  it('follows a 206 page only when it includes a next cursor, and stops at the request budget', async () => {
    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (!maxId) {
        return Promise.resolve({
          status: 206,
          data: [{ id: '800', account: '2' }],
          links: nextLink(path, '400'),
        });
      }

      return Promise.resolve({
        status: 200,
        data: [{ id: '400', account: '2' }],
        headers: {},
      });
    });

    const { dispatch, getState } = harness();

    await loadMixTimeline('column:next', deferredMix)(dispatch, getState);

    const sources = getState().getIn(['mix_timelines', 'column:next', 'sources']);

    expect(mockGet).toHaveBeenCalledTimes(4);
    expect(sources.every(source => source.get('suspended') === false)).toBe(true);
    expect(sources.every(source => source.get('frontier') === '400')).toBe(true);
    expect(sources.every(source => source.get('ids').toArray().join(',') === '800,400')).toBe(true);

    mockGet.mockReset();
    let cursor = 900;

    mockGet.mockImplementation((path) => {
      cursor -= 1;

      return Promise.resolve({
        status: 206,
        data: [{ id: String(1000 + cursor), account: '2' }],
        links: nextLink(path, String(cursor)),
      });
    });

    await loadMixTimeline('column:budget', deferredMix)(dispatch, getState);
    expect(mockGet).toHaveBeenCalledTimes(MIX_FETCH_BUDGET);
  });

  it('stops after a 206 page with no next link and completes that source on an explicit retry', async () => {
    mockGet.mockImplementation(() => Promise.resolve({
      status: 206,
      data: [{ id: '500', account: '2' }],
      headers: {},
    }));

    const { dispatch, getState } = harness();
    const publicKey = sourceKey({ type: 'public', params: {} });
    const remoteKey = sourceKey({ type: 'remote', params: {} });

    await loadMixTimeline('column:partial', deferredMix)(dispatch, getState);

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources']).every(source => source.get('suspended') === true)).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources']).every(source => source.get('frontier') === null)).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'ids']).toArray()).toEqual(['500']);

    mockGet.mockClear();
    await loadMixTimeline('column:partial', deferredMix, { extend: true })(dispatch, getState);
    expect(mockGet).not.toHaveBeenCalled();

    mockGet.mockImplementation((path, config) => {
      if (config && config.params && config.params.remote) {
        return Promise.resolve({ status: 206, data: [{ id: '450', account: '2' }], headers: {} });
      }

      return Promise.resolve({ status: 200, data: [{ id: '300', account: '2' }], headers: {} });
    });

    await retryMixSource('column:partial', deferredMix, publicKey)(dispatch, getState);

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(remoteCall(mockGet.mock.calls[0])).toBe(false);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'ids']).toArray()).toEqual(['500', '300']);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'suspended'])).toBe(false);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'frontier'])).toBe('300');
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', remoteKey, 'suspended'])).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', remoteKey, 'ids']).toArray()).toEqual(['500']);

    mockGet.mockClear();
    await retryMixSource('column:partial', deferredMix, remoteKey)(dispatch, getState);

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(remoteCall(mockGet.mock.calls[0])).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', remoteKey, 'suspended'])).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', remoteKey, 'ids']).toArray()).toEqual(['500', '450']);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'ids']).toArray()).toEqual(['500', '300']);
    expect(mockGet).toHaveBeenCalledTimes(1);
  });

  it('retries only the requested failed source and keeps a future rate limit', async () => {
    mockGet.mockImplementation((path, config) => {
      if (config && config.params && config.params.remote) {
        return Promise.reject({ response: { status: 429, headers: { 'retry-after': '120' } } });
      }

      return Promise.reject({ response: { status: 500 } });
    });

    const { dispatch, getState } = harness();
    const publicKey = sourceKey({ type: 'public', params: {} });
    const remoteKey = sourceKey({ type: 'remote', params: {} });

    await loadMixTimeline('column:failed', deferredMix)(dispatch, getState);

    const retryAt = getState().getIn(['mix_timelines', 'column:failed', 'sources', remoteKey, 'retryAt']);

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(getState().getIn(['mix_timelines', 'column:failed', 'sources', publicKey, 'error'])).toBe('server');
    expect(getState().getIn(['mix_timelines', 'column:failed', 'sources', remoteKey, 'error'])).toBe('rate_limit');
    expect(retryAt).toBeGreaterThan(Date.now());

    mockGet.mockReset();
    mockGet.mockImplementation(() => Promise.resolve({ status: 200, data: [{ id: '300', account: '2' }], headers: {} }));
    await retryMixSource('column:failed', deferredMix, publicKey)(dispatch, getState);

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(remoteCall(mockGet.mock.calls[0])).toBe(false);
    expect(getState().getIn(['mix_timelines', 'column:failed', 'sources', publicKey, 'ids']).toArray()).toEqual(['300']);
    expect(getState().getIn(['mix_timelines', 'column:failed', 'sources', publicKey, 'error'])).toBe(null);
    expect(getState().getIn(['mix_timelines', 'column:failed', 'sources', remoteKey, 'error'])).toBe('rate_limit');
    expect(getState().getIn(['mix_timelines', 'column:failed', 'sources', remoteKey, 'retryAt'])).toBe(retryAt);

    mockGet.mockClear();
    await retryMixSource('column:failed', deferredMix, remoteKey)(dispatch, getState);
    expect(mockGet).not.toHaveBeenCalled();
    expect(getState().getIn(['mix_timelines', 'column:failed', 'sources', remoteKey, 'retryAt'])).toBe(retryAt);
    expect(getState().getIn(['mix_timelines', 'column:failed', 'sources', publicKey, 'ids']).toArray()).toEqual(['300']);
  });

  it('does not apply a late success or failure to the column that replaced it', async () => {
    const waiting = [];
    let hold = true;

    mockGet.mockImplementation(() => {
      if (hold) {
        return new Promise((resolve, reject) => waiting.push({ resolve, reject }));
      }

      return Promise.resolve(page('200'));
    });

    const { dispatch, getState } = harness();
    const first = loadMixTimeline('column:one', deferredMix)(dispatch, getState);

    await Promise.resolve();
    expect(waiting.length).toBe(2);
    dispatch(closeMixTimeline('column:one'));
    hold = false;
    await loadMixTimeline('column:two', deferredMix)(dispatch, getState);
    waiting[0].resolve(page('100'));
    waiting[1].reject({ response: { status: 500 } });
    await first;

    const current = getState().getIn(['mix_timelines', 'column:two', 'sources']);

    expect(getState().get('mix_timelines').has('column:one')).toBe(false);
    expect(current.valueSeq().every(source => source.get('error') === null)).toBe(true);
    expect(current.valueSeq().flatMap(source => source.get('ids')).toArray()).toEqual(['200', '200']);
  });
});