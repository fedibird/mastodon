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
  importFetchedAccounts: (accounts) => ({ type: 'IMPORT_ACCOUNTS', accounts }),
  importFilters: (filters) => ({ type: 'FILTERS_IMPORT', filters }),
}));

const mockGet = jest.fn();

import { fromJS } from 'immutable';
import mixTimelines from '../../reducers/mix_timelines';
import relationships from '../../reducers/relationships';
import { closeMixTimeline, createMixSplit, destroyMixSplit, loadMixTimeline, retryMixSource } from '../mix_timelines';
import { MIX_FETCH_BUDGET } from '../../mix/merge';
import { sourceKey } from '../../mix/source';
import { mixTimelineView } from '../../mix/view';

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
    let heads = 0;

    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (!maxId) {
        heads += 1;

        if (heads <= 2) {
          return Promise.resolve({
            status: 206,
            data: [{ id: '800', account: '2' }],
            links: nextLink(path, '400'),
          });
        }

        return Promise.resolve({
          status: 200,
          data: [{ id: '800', account: '2' }, { id: '400', account: '2' }],
          headers: {},
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

    expect(mockGet).toHaveBeenCalledTimes(6);
    expect(sources.every(source => source.get('suspended') === false)).toBe(true);
    expect(sources.every(source => source.get('gap') === false)).toBe(true);
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
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'ids']).toArray()).toEqual(['300']);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'suspended'])).toBe(false);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'gap'])).toBe(false);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'frontier'])).toBe('300');
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', remoteKey, 'suspended'])).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', remoteKey, 'ids']).toArray()).toEqual(['500']);

    mockGet.mockClear();
    await retryMixSource('column:partial', deferredMix, remoteKey)(dispatch, getState);

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(remoteCall(mockGet.mock.calls[0])).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', remoteKey, 'suspended'])).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', remoteKey, 'ids']).toArray()).toEqual(['500', '450']);
    expect(getState().getIn(['mix_timelines', 'column:partial', 'sources', publicKey, 'ids']).toArray()).toEqual(['300']);
    expect(mockGet).toHaveBeenCalledTimes(1);
  });

  const rebuildMix = fromJS({
    id: 'mix-1',
    version: 1,
    title: 'Desk',
    sources: [
      { type: 'home', params: {} },
      { type: 'public', params: {} },
    ],
  });

  const homeEntry = (state, columnKey) => {
    let found = null;

    state.getIn(['mix_timelines', columnKey, 'sources']).forEach((source, key) => {
      if (source.getIn(['descriptor', 'type']) === 'home') {
        found = { key, source };
      }
    });

    return found;
  };

  it('does not treat a 200 after 206 as complete until the source is reread from the start', async () => {
    let homeHeads = 0;
    let releaseReread;
    const reread = new Promise(resolve => {
      releaseReread = resolve;
    });

    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (path === '/api/v1/timelines/home') {
        if (!maxId) {
          homeHeads += 1;

          if (homeHeads === 1) {
            return Promise.resolve({
              status: 206,
              data: [{ id: '100', account: '2' }, { id: '80', account: '2' }],
              links: nextLink(path, '80'),
            });
          }

          return reread.then(() => Promise.resolve({
            status: 200,
            data: [
              { id: '100', account: '2' },
              { id: '90', account: '2' },
              { id: '80', account: '2' },
              { id: '70', account: '2' },
              { id: '60', account: '2' },
            ],
            headers: {},
          }));
        }

        return Promise.resolve({
          status: 200,
          data: [{ id: '70', account: '2' }, { id: '60', account: '2' }],
          headers: {},
        });
      }

      return Promise.resolve({ status: 200, data: [{ id: '100', account: '2' }], headers: {} });
    });

    const { dispatch, getState } = harness();
    const pending = loadMixTimeline('column:rebuild', rebuildMix)(dispatch, getState);

    for (let attempt = 0; attempt < 30 && homeHeads < 2; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 0));
    }

    const homeCalls = mockGet.mock.calls.filter(call => call[0] === '/api/v1/timelines/home');
    const midway = homeEntry(getState(), 'column:rebuild').source;
    const midwayView = mixTimelineView(getState().getIn(['mix_timelines', 'column:rebuild']), getState().get('statuses'), null, null);

    expect(homeHeads).toBe(2);
    expect(homeCalls.map(call => (call[1].params.max_id || null))).toEqual([null, '80', null]);
    expect(midway.get('ids').toArray()).toEqual(['100', '80', '70', '60']);
    expect(midway.get('gap')).toBe(true);
    expect(midway.get('frontier')).toBe(null);
    expect(midwayView.orderGuaranteed).toBe(false);
    expect(midwayView.statusIds.toArray()).toEqual(['100', '80', '70', '60']);

    releaseReread();
    await pending;

    const rebuilt = homeEntry(getState(), 'column:rebuild').source;
    const rebuiltView = mixTimelineView(getState().getIn(['mix_timelines', 'column:rebuild']), getState().get('statuses'), null, null);

    expect(rebuilt.get('ids').toArray()).toEqual(['100', '90', '80', '70', '60']);
    expect(rebuilt.get('gap')).toBe(false);
    expect(rebuilt.get('frontier')).toBe('60');
    expect(rebuiltView.orderGuaranteed).toBe(true);
    expect(rebuiltView.statusIds.toArray()).toEqual(['100', '90', '80', '70', '60']);
    expect(mockGet.mock.calls.filter(call => call[0] === '/api/v1/timelines/home')).toHaveLength(3);
  });

  it('stops rereading when the rebuilt page is still partial', async () => {
    let homeHeads = 0;

    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (path === '/api/v1/timelines/home') {
        if (!maxId) {
          homeHeads += 1;

          return Promise.resolve({
            status: 206,
            data: [{ id: '100', account: '2' }, { id: '80', account: '2' }],
            links: nextLink(path, '80'),
          });
        }

        return Promise.resolve({
          status: 200,
          data: [{ id: '70', account: '2' }, { id: '60', account: '2' }],
          headers: {},
        });
      }

      return Promise.resolve({ status: 200, data: [{ id: '100', account: '2' }], headers: {} });
    });

    const { dispatch, getState } = harness();

    await loadMixTimeline('column:stuck', rebuildMix)(dispatch, getState);

    const stuck = homeEntry(getState(), 'column:stuck');
    const stuckView = mixTimelineView(getState().getIn(['mix_timelines', 'column:stuck']), getState().get('statuses'), null, null);

    expect(homeHeads).toBe(2);
    expect(mockGet.mock.calls.filter(call => call[0] === '/api/v1/timelines/home')).toHaveLength(3);
    expect(stuck.source.get('ids').toArray()).toEqual(['100', '80', '70', '60']);
    expect(stuck.source.get('gap')).toBe(true);
    expect(stuck.source.get('suspended')).toBe(true);
    expect(stuck.source.get('frontier')).toBe(null);
    expect(stuckView.orderGuaranteed).toBe(false);
    expect(stuckView.suspended.map(item => item.key)).toContain(stuck.key);
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

  const headPage = () => {
    const data = [];

    for (let value = 90; value >= 51; value -= 1) {
      data.push({ id: String(value), account: '2' });
    }

    return data;
  };

  it('pages history on each source cursor without moving the live cursors', async () => {
    const publicKey = sourceKey({ type: 'public', params: {} });
    const remoteKey = sourceKey({ type: 'remote', params: {} });

    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (!maxId) {
        return Promise.resolve({
          status: 200,
          data: headPage(),
          links: nextLink(path, '50'),
        });
      }

      const id = config.params.remote ? '30' : '40';

      return Promise.resolve({
        status: 200,
        data: [{ id, account: '2' }],
        headers: {},
      });
    });

    const { dispatch, getState } = harness();

    await loadMixTimeline('column:hist', deferredMix)(dispatch, getState);
    createMixSplit('column:hist', 'split-h')(dispatch, getState);
    await loadMixTimeline('column:hist', deferredMix, { extend: true, scope: 'history', splitId: 'split-h' })(dispatch, getState);

    const column = getState().getIn(['mix_timelines', 'column:hist']);
    const history = mixTimelineView(column, null, null, null, 'history');
    const live = mixTimelineView(column, null, null, null, 'live');
    const recent = headPage().map(item => item.id);

    expect(column.getIn(['sources', publicKey, 'cursor'])).toBe('50');
    expect(column.getIn(['sources', remoteKey, 'cursor'])).toBe('50');
    expect(column.getIn(['split', 'history', 'sources', publicKey, 'ids']).last()).toBe('40');
    expect(column.getIn(['split', 'history', 'sources', remoteKey, 'ids']).last()).toBe('30');
    expect(history.statusIds.take(40).toArray()).toEqual(recent);
    expect(history.statusIds.slice(40).toArray()).toEqual(['40', '30']);
    expect(live.statusIds.toArray()).toEqual(recent);
    expect(live.statusIds.contains('40')).toBe(false);
    expect(history.orderGuaranteed).toBe(true);
  });

  it('ignores a late history page after the split closes and keeps a 429 on history', async () => {
    const publicKey = sourceKey({ type: 'public', params: {} });
    const remoteKey = sourceKey({ type: 'remote', params: {} });
    const waiting = [];
    let hold = false;

    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (!maxId) {
        return Promise.resolve({
          status: 200,
          data: headPage(),
          links: nextLink(path, '50'),
        });
      }

      if (!hold) {
        return Promise.resolve({
          status: 200,
          data: [{ id: '45', account: '2' }],
          headers: {},
        });
      }

      if (config.params.remote) {
        return Promise.reject({ response: { status: 429, headers: { 'retry-after': '8' } } });
      }

      return new Promise(resolve => waiting.push(resolve));
    });

    const { dispatch, getState } = harness();

    await loadMixTimeline('column:hist', deferredMix)(dispatch, getState);
    createMixSplit('column:hist', 'split-h')(dispatch, getState);
    hold = true;
    const historyLoad = loadMixTimeline('column:hist', deferredMix, { extend: true, scope: 'history', splitId: 'split-h' })(dispatch, getState);

    for (let attempt = 0; attempt < 10; attempt += 1) {
      await Promise.resolve();

      if (waiting.length > 0 && getState().getIn(['mix_timelines', 'column:hist', 'split', 'history', 'sources', remoteKey, 'error']) === 'rate_limit') {
        break;
      }
    }

    expect(waiting.length).toBe(1);
    expect(getState().getIn(['mix_timelines', 'column:hist', 'split', 'history', 'sources', remoteKey, 'error'])).toBe('rate_limit');
    expect(getState().getIn(['mix_timelines', 'column:hist', 'sources', remoteKey, 'error'])).toBe(null);
    expect(mixTimelineView(getState().getIn(['mix_timelines', 'column:hist']), null, null, null, 'history').orderGuaranteed).toBe(false);

    destroyMixSplit('column:hist', 'split-h', { keep: 'live' })(dispatch, getState);
    waiting[0]({
      status: 200,
      data: [{ id: '10', account: '2' }],
      headers: {},
    });
    await historyLoad;

    const column = getState().getIn(['mix_timelines', 'column:hist']);

    expect(column.get('split')).toBeUndefined();
    expect(column.getIn(['sources', publicKey, 'cursor'])).toBe('50');
    expect(column.getIn(['sources', publicKey, 'ids']).contains('10')).toBe(false);
    expect(column.getIn(['sources', remoteKey, 'error'])).toBe(null);
    expect(mixTimelineView(column, null, null, null).statusIds.contains('10')).toBe(false);
  });

  const staleHistoryPage = () => ({
    status: 200,
    data: {
      statuses: [{
        id: '10',
        account: { id: '8', username: 'late' },
        visibility: 'public',
        filtered: [{ filter: { id: '77', title: 'Late', context: ['public'], filter_action: 'warn' } }],
      }],
      accounts: [{ id: '8', username: 'late' }],
      relationships: [{ id: '8', following: false, blocking: false, muting: false }],
    },
    headers: {},
  });

  const recordingHarness = () => {
    let state = fromJS({
      settings: { mixes: [] },
      timelines: { home: { items: ['existing'] } },
      statuses: {},
      relationships: {},
      mix_timelines: {},
    });
    const sent = [];
    const dispatch = (action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => state);
      }

      sent.push(action);

      if (action.type && action.type.indexOf('MIX_') === 0) {
        state = state.set('mix_timelines', mixTimelines(state.get('mix_timelines'), action));
      }

      if (action.type === 'ACCOUNT_BLOCK_SUCCESS' || action.type === 'ACCOUNT_MUTE_SUCCESS' || action.type === 'ACCOUNT_UNBLOCK_SUCCESS' || action.type === 'ACCOUNT_UNMUTE_SUCCESS') {
        state = state.set('relationships', relationships(state.get('relationships'), action));
        state = state.set('mix_timelines', mixTimelines(state.get('mix_timelines'), action));
      }

      if (action.type === 'RELATIONSHIPS_FETCH_SUCCESS') {
        state = state.set('relationships', relationships(state.get('relationships'), action));
      }

      return action;
    };

    return {
      dispatch,
      getState: () => state,
      sent,
    };
  };

  const holdHistoryExtend = async () => {
    const waiting = [];
    let mode = 'open';
    const publicKey = sourceKey({ type: 'public', params: {} });
    const remoteKey = sourceKey({ type: 'remote', params: {} });

    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (mode === 'fresh') {
        return Promise.resolve({
          status: 200,
          data: [{ id: '20', account: { id: '3' }, visibility: 'public' }],
          headers: {},
        });
      }

      if (!maxId) {
        return Promise.resolve({
          status: 200,
          data: headPage(),
          links: nextLink(path, '50'),
        });
      }

      if (mode !== 'hold') {
        return Promise.resolve({
          status: 200,
          data: [{ id: '45', account: { id: '3' }, visibility: 'public' }],
          headers: {},
        });
      }

      return new Promise(resolve => waiting.push(resolve));
    });

    const recorded = recordingHarness();

    await loadMixTimeline('column:hist', deferredMix)(recorded.dispatch, recorded.getState);
    createMixSplit('column:hist', 'split-a')(recorded.dispatch, recorded.getState);
    mode = 'hold';
    const pending = loadMixTimeline('column:hist', deferredMix, {
      extend: true,
      scope: 'history',
      splitId: 'split-a',
    })(recorded.dispatch, recorded.getState);

    for (let attempt = 0; attempt < 10 && waiting.length < 2; attempt += 1) {
      await Promise.resolve();
    }

    expect(waiting.length).toBe(2);
    recorded.sent.length = 0;

    return {
      ...recorded,
      waiting,
      pending,
      publicKey,
      remoteKey,
      setMode (next) {
        mode = next;
      },
    };
  };

  const importsOf = (sent, type) => sent.filter(action => action.type === type);

  const releaseStale = async (held) => {
    held.waiting.forEach(resolve => resolve(staleHistoryPage()));
    await held.pending;
  };

  it('drops a history response from an older split before importing it', async () => {
    const held = await holdHistoryExtend();

    destroyMixSplit('column:hist', 'split-a', { keep: 'live' })(held.dispatch, held.getState);
    createMixSplit('column:hist', 'split-b')(held.dispatch, held.getState);
    await releaseStale(held);

    const column = held.getState().getIn(['mix_timelines', 'column:hist']);

    expect(column.getIn(['split', 'id'])).toBe('split-b');
    expect(column.getIn(['split', 'history', 'sources', held.publicKey, 'ids']).contains('10')).toBe(false);
    expect(column.getIn(['sources', held.publicKey, 'cursor'])).toBe('50');
    expect(column.getIn(['sources', held.remoteKey, 'cursor'])).toBe('50');
    expect(importsOf(held.sent, 'IMPORT_STATUSES')).toEqual([]);
    expect(importsOf(held.sent, 'IMPORT_ACCOUNTS')).toEqual([]);
    expect(importsOf(held.sent, 'FILTERS_IMPORT')).toEqual([]);
    expect(importsOf(held.sent, 'RELATIONSHIPS_FETCH_SUCCESS')).toEqual([]);
  });

  it('drops a history response after keeping history, keeping live, changing the definition, or closing the column', async () => {
    const keptHistory = await holdHistoryExtend();

    destroyMixSplit('column:hist', 'split-a', { keep: 'history', historyAtTop: false })(keptHistory.dispatch, keptHistory.getState);
    await releaseStale(keptHistory);

    expect(keptHistory.getState().getIn(['mix_timelines', 'column:hist', 'split'])).toBeUndefined();
    expect(keptHistory.getState().getIn(['mix_timelines', 'column:hist', 'sources', keptHistory.publicKey, 'ids']).contains('10')).toBe(false);
    expect(keptHistory.getState().getIn(['mix_timelines', 'column:hist', 'sources', keptHistory.publicKey, 'cursor'])).toBe('50');
    expect(importsOf(keptHistory.sent, 'IMPORT_STATUSES')).toEqual([]);

    const keptLive = await holdHistoryExtend();

    destroyMixSplit('column:hist', 'split-a', { keep: 'live' })(keptLive.dispatch, keptLive.getState);
    await releaseStale(keptLive);
    expect(keptLive.getState().getIn(['mix_timelines', 'column:hist', 'sources', keptLive.publicKey, 'cursor'])).toBe('50');
    expect(importsOf(keptLive.sent, 'IMPORT_ACCOUNTS')).toEqual([]);

    const redefined = await holdHistoryExtend();
    const other = fromJS({
      id: 'mix-1',
      version: 1,
      title: 'Desk',
      sources: [
        { type: 'public', params: {} },
        { type: 'home', params: {} },
      ],
    });

    redefined.setMode('fresh');
    await loadMixTimeline('column:hist', other)(redefined.dispatch, redefined.getState);
    redefined.sent.length = 0;
    await releaseStale(redefined);
    expect(redefined.getState().getIn(['mix_timelines', 'column:hist', 'sources']).valueSeq().flatMap(source => source.get('ids')).toArray()).not.toContain('10');
    expect(importsOf(redefined.sent, 'IMPORT_STATUSES')).toEqual([]);
    expect(importsOf(redefined.sent, 'FILTERS_IMPORT')).toEqual([]);

    const closed = await holdHistoryExtend();

    closed.dispatch(closeMixTimeline('column:hist'));
    await releaseStale(closed);
    expect(closed.getState().get('mix_timelines').has('column:hist')).toBe(false);
    expect(importsOf(closed.sent, 'IMPORT_STATUSES')).toEqual([]);
    expect(importsOf(closed.sent, 'RELATIONSHIPS_FETCH_SUCCESS')).toEqual([]);
  });

  it('does not restore a blocked or muted account from a history page that was already in flight', async () => {
    const waiting = [];
    let hold = false;

    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (!maxId) {
        return Promise.resolve({
          status: 200,
          data: headPage().map(item => ({ ...item, account: { id: item.id === '80' ? '4' : '2' }, visibility: 'public' })),
          links: nextLink(path, '50'),
        });
      }

      if (!hold) {
        return Promise.resolve({
          status: 200,
          data: [{ id: '45', account: { id: '4' }, visibility: 'public' }],
          headers: {},
        });
      }

      return new Promise(resolve => waiting.push(resolve));
    });

    const { dispatch, getState } = recordingHarness();
    const publicKey = sourceKey({ type: 'public', params: {} });
    const remoteKey = sourceKey({ type: 'remote', params: {} });

    await loadMixTimeline('column:hist', deferredMix)(dispatch, getState);
    createMixSplit('column:hist', 'split-a')(dispatch, getState);
    hold = true;
    const pending = loadMixTimeline('column:hist', deferredMix, {
      extend: true,
      scope: 'history',
      splitId: 'split-a',
    })(dispatch, getState);

    for (let attempt = 0; attempt < 10 && waiting.length < 2; attempt += 1) {
      await Promise.resolve();
    }

    dispatch({
      type: 'ACCOUNT_BLOCK_SUCCESS',
      relationship: { id: '2', blocking: true, muting: false },
      statuses: fromJS([
        { id: '90', account: '2' },
        { id: '88', account: '9', reblog: '90' },
      ]),
    });

    waiting.forEach(resolve => resolve({
      status: 200,
      data: [
        { id: '16', account: { id: '9' }, visibility: 'public', reblog: { id: '14', account: { id: '2' }, visibility: 'public' } },
        { id: '15', account: { id: '2' }, visibility: 'public' },
        { id: '12', account: { id: '4' }, visibility: 'public' },
      ],
      links: { refs: [{ rel: 'next', uri: `${window.location.origin}/api/v1/timelines/public?max_id=11` }] },
    }));
    await pending;

    const column = getState().getIn(['mix_timelines', 'column:hist']);
    const history = mixTimelineView(column, getState().get('statuses'), null, null, 'history');
    const live = mixTimelineView(column, getState().get('statuses'), null, null, 'live');
    const single = mixTimelineView(column, getState().get('statuses'), null, null);

    expect(column.getIn(['split', 'history', 'sources', publicKey, 'ids']).toArray()).not.toEqual(expect.arrayContaining(['15', '16', '90']));
    expect(column.getIn(['split', 'history', 'sources', remoteKey, 'ids']).toArray()).not.toEqual(expect.arrayContaining(['15', '16', '90']));
    expect(history.statusIds.toArray()).toEqual(expect.arrayContaining(['12']));
    expect(history.statusIds.toArray()).not.toEqual(expect.arrayContaining(['15', '16', '90']));
    expect(live.statusIds.toArray()).not.toEqual(expect.arrayContaining(['15', '16', '90']));
    expect(single.statusIds.toArray()).not.toEqual(expect.arrayContaining(['15', '16', '90']));

    dispatch({
      type: 'ACCOUNT_UNBLOCK_SUCCESS',
      relationship: { id: '2', blocking: false, muting: false },
    });
    hold = false;
    mockGet.mockImplementation(() => Promise.resolve({
      status: 200,
      data: [{ id: '15', account: { id: '2' }, visibility: 'public' }],
      headers: {},
    }));
    await loadMixTimeline('column:hist', deferredMix, {
      extend: true,
      scope: 'history',
      splitId: 'split-a',
    })(dispatch, getState);

    expect(getState().getIn(['mix_timelines', 'column:hist', 'split', 'history', 'sources', publicKey, 'ids']).contains('15')).toBe(true);
  });

  const compactRacePage = () => ({
    status: 200,
    data: {
      statuses: [
        { id: '100', account: { id: '42' }, visibility: 'public' },
      ],
      accounts: [
        { id: '42', username: 'alice' },
      ],
      relationships: [
        { id: '42', blocking: false, muting: false },
        { id: '7', following: true, blocking: false, muting: false },
      ],
    },
    headers: {},
  });

  const relationshipAction = (kind, active) => ({
    type: {
      block: active ? 'ACCOUNT_BLOCK_SUCCESS' : 'ACCOUNT_UNBLOCK_SUCCESS',
      mute: active ? 'ACCOUNT_MUTE_SUCCESS' : 'ACCOUNT_UNMUTE_SUCCESS',
    }[kind],
    relationship: {
      id: '42',
      blocking: kind === 'block' && active,
      muting: kind === 'mute' && active,
      following: true,
    },
    statuses: fromJS([]),
  });

  it.each(['block', 'mute'])('keeps a %s set during a single-view compact response', async (kind) => {
    const waiting = [];

    mockGet.mockImplementation(() => new Promise(resolve => waiting.push(resolve)));

    const { dispatch, getState } = recordingHarness();
    const publicKey = sourceKey({ type: 'public', params: {} });
    const remoteKey = sourceKey({ type: 'remote', params: {} });
    const pending = loadMixTimeline('column:race', deferredMix)(dispatch, getState);

    for (let attempt = 0; attempt < 10 && waiting.length < 2; attempt += 1) {
      await Promise.resolve();
    }

    dispatch(relationshipAction(kind, true));
    waiting.splice(0).forEach(resolve => resolve(compactRacePage()));
    await pending;

    const relationship = getState().getIn(['relationships', '42']);
    const column = getState().getIn(['mix_timelines', 'column:race']);
    const single = mixTimelineView(column, getState().get('statuses'), null, null);

    expect(relationship.get(kind === 'mute' ? 'muting' : 'blocking')).toBe(true);
    expect(relationship.get('following')).toBe(true);
    expect(getState().getIn(['relationships', '7', 'following'])).toBe(true);
    expect(column.getIn(['sources', publicKey, 'ids']).contains('100')).toBe(false);
    expect(column.getIn(['sources', remoteKey, 'ids']).contains('100')).toBe(false);
    expect(single.statusIds.contains('100')).toBe(false);

    dispatch(relationshipAction(kind, false));
    mockGet.mockImplementation(() => Promise.resolve(compactRacePage()));
    await retryMixSource('column:race', deferredMix, publicKey)(dispatch, getState);
    await retryMixSource('column:race', deferredMix, remoteKey)(dispatch, getState);

    expect(getState().getIn(['mix_timelines', 'column:race', 'sources', publicKey, 'ids']).contains('100')).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:race', 'sources', remoteKey, 'ids']).contains('100')).toBe(true);
  });

  it.each(['block', 'mute'])('keeps a %s set during a history compact response', async (kind) => {
    const { dispatch, getState } = recordingHarness();
    const publicKey = sourceKey({ type: 'public', params: {} });
    const remoteKey = sourceKey({ type: 'remote', params: {} });
    const waiting = [];
    let hold = false;

    mockGet.mockImplementation((path, config) => {
      const maxId = config && config.params && config.params.max_id;

      if (!hold) {
        if (!maxId) {
          return Promise.resolve({
            status: 200,
            data: headPage(),
            links: nextLink(path, '50'),
          });
        }

        return Promise.resolve({
          status: 200,
          data: [{ id: '45', account: { id: '3' }, visibility: 'public' }],
          headers: {},
        });
      }

      return new Promise(resolve => waiting.push(resolve));
    });

    await loadMixTimeline('column:hist', deferredMix)(dispatch, getState);
    createMixSplit('column:hist', 'split-a')(dispatch, getState);
    hold = true;
    const pending = loadMixTimeline('column:hist', deferredMix, {
      extend: true,
      scope: 'history',
      splitId: 'split-a',
    })(dispatch, getState);

    for (let attempt = 0; attempt < 10 && waiting.length < 2; attempt += 1) {
      await Promise.resolve();
    }

    dispatch(relationshipAction(kind, true));
    waiting.forEach(resolve => resolve(compactRacePage()));
    await pending;

    const column = getState().getIn(['mix_timelines', 'column:hist']);
    const history = mixTimelineView(column, getState().get('statuses'), null, null, 'history');
    const live = mixTimelineView(column, getState().get('statuses'), null, null, 'live');
    const single = mixTimelineView(column, getState().get('statuses'), null, null);

    expect(getState().getIn(['relationships', '42', kind === 'mute' ? 'muting' : 'blocking'])).toBe(true);
    expect(getState().getIn(['relationships', '42', 'following'])).toBe(true);
    expect(column.getIn(['split', 'history', 'sources', publicKey, 'ids']).contains('100')).toBe(false);
    expect(column.getIn(['split', 'history', 'sources', remoteKey, 'ids']).contains('100')).toBe(false);
    expect(history.statusIds.contains('100')).toBe(false);
    expect(live.statusIds.contains('100')).toBe(false);
    expect(single.statusIds.contains('100')).toBe(false);

    dispatch(relationshipAction(kind, false));
    mockGet.mockImplementation(() => Promise.resolve(compactRacePage()));
    await retryMixSource('column:hist', deferredMix, publicKey, { scope: 'history', splitId: 'split-a' })(dispatch, getState);

    expect(getState().getIn(['mix_timelines', 'column:hist', 'split', 'history', 'sources', publicKey, 'ids']).contains('100')).toBe(true);
  });
});