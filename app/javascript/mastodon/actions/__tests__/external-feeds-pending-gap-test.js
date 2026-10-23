jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));
jest.mock('../../stream', () => ({ connectStream: (channel, params, factory) => factory }));
jest.mock('../../initial_state', () => ({
  usePendingItems: true,
  me: '1',
  enableLimitedTimeline: false,
  hideDirectFromTimeline: false,
  hidePersonalFromTimeline: false,
  expandSpoilers: false,
  autoPlayEmoji: false,
  isAdministrator: false,
  new_features_policy: 'tester',
}));
jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: () => ({ refs: [] }),
}));

import { fromJS } from 'immutable';

import api from '../../api';
import { connectTimelineStream } from '../streaming';
import { discardExternalFeedSessionForTests } from '../external_feeds';
import timelinesReducer from '../../reducers/timelines';

const drain = async () => {
  for (let step = 0; step < 20; step += 1) {
    await Promise.resolve();
  }
};

describe('reconnect gap with pending items', () => {
  afterEach(() => {
    discardExternalFeedSessionForTests();
  });

  it('uses the pending id behind the disconnect gap', async () => {
    const calls = [];
    let state = fromJS({
      meta: { locale: 'en' },
      externalFeeds: { permitted: false },
      settings: { home: { shows: {} } },
      markers: { home: '9999' },
      notifications: {},
      timelines: {
        home: {
          items: ['80', '70'],
          pendingItems: ['90', '85'],
          isLoading: false,
          hasMore: true,
          online: true,
        },
      },
      statuses: {},
      accounts: {},
    });
    const dispatch = (action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => state);
      }

      state = state.set('timelines', timelinesReducer(state.get('timelines'), action));
      return action;
    };

    api.mockImplementation(() => ({
      get: (path, config) => {
        calls.push({ path, params: (config && config.params) || {} });
        return Promise.resolve({ status: 200, headers: {}, data: [] });
      },
      post: () => Promise.resolve({ status: 200, headers: {}, data: { outcome: 'complete', results: [] } }),
    }));

    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    home.onDisconnect();
    expect(state.getIn(['timelines', 'home', 'pendingItems']).toArray()).toEqual([null, '90', '85']);
    expect(state.getIn(['timelines', 'home', 'items']).toArray()).toEqual(['80', '70']);
    home.onConnect();
    await drain();

    const recent = calls.find(call => call.path === '/api/v1/timelines/home' && call.params.since_id);

    expect(recent.params.since_id).toBe('90');
    expect(state.getIn(['timelines', 'home', 'pendingItems']).first()).toBe(null);
  });
});
