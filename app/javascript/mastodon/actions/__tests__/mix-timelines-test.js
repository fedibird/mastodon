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
  getLinks: () => ({ refs: [] }),
}));

jest.mock('../importer', () => ({
  importFetchedStatuses: (statuses) => ({ type: 'IMPORT_STATUSES', statuses }),
}));

const mockGet = jest.fn();

import { fromJS } from 'immutable';
import mixTimelines from '../../reducers/mix_timelines';
import { closeMixTimeline, loadMixTimeline } from '../mix_timelines';

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
});