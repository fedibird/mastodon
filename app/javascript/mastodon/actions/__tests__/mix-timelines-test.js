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
import { loadMixTimeline } from '../mix_timelines';

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
});