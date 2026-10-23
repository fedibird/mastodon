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

import { Map as ImmutableMap, fromJS } from 'immutable';

import api from '../../api';
import { connectTimelineStream } from '../streaming';
import { discardExternalFeedSessionForTests } from '../external_feeds';
import timelinesReducer from '../../reducers/timelines';
import statusesReducer from '../../reducers/statuses';
import accountsReducer from '../../reducers/accounts';
import relationshipsReducer from '../../reducers/relationships';

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

  it('keeps a streamed id between the remaining reconnect rows', async () => {
    const account = {
      id: '2',
      username: 'ada',
      acct: 'ada',
      display_name: 'Ada',
      note: '',
      url: 'https://example.test/@ada',
      emojis: [],
      followed_message: '',
    };
    const body = (id, content) => ({
      id,
      content,
      account,
      created_at: '2020-01-01T00:00:00.000Z',
      visibility: 'public',
      emojis: [],
      media_attachments: [],
    });
    const page = {
      status: 200,
      headers: {},
      data: {
        statuses: [body('110', '<p>newer</p>'), body('100', '<p>OLD</p>'), body('90', '<p>between</p>')],
        accounts: [account],
        referenced_statuses: [],
        relationships: [],
      },
    };
    const timelines = [
      ['home', 'user', {}],
      ['list:4', 'list', { list: '4' }],
    ];

    for (let index = 0; index < timelines.length; index += 1) {
      const [timelineId, channel, params] = timelines[index];
      let state = fromJS({
        meta: { locale: 'en', me: '1' },
        externalFeeds: { permitted: false },
        settings: { home: { shows: {} } },
        markers: { home: '9999' },
        notifications: {},
        timelines: {
          [timelineId]: {
            items: ['80', '70'],
            pendingItems: [],
            isLoading: false,
            hasMore: true,
            online: true,
            top: true,
          },
        },
        statuses: {},
        accounts: {},
        relationships: {},
        polls: {},
      });
      const dispatch = (action) => {
        if (typeof action === 'function') {
          return action(dispatch, () => state);
        }

        state = state
          .set('timelines', timelinesReducer(state.get('timelines'), action))
          .set('statuses', statusesReducer(state.get('statuses'), action))
          .set('accounts', accountsReducer(state.get('accounts'), action))
          .set('relationships', relationshipsReducer(state.get('relationships'), action));
        return action;
      };
      let releasePage;
      const arm = () => {
        api.mockImplementation(() => ({
          get: (path, config) => {
            if (config && config.params && config.params.since_id) {
              return new Promise(resolve => {
                releasePage = resolve;
              });
            }

            return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
          },
          post: () => Promise.resolve({ status: 200, headers: {}, data: { outcome: 'complete', results: [] } }),
        }));
      };
      const pending = () => state.getIn(['timelines', timelineId, 'pendingItems']).toArray();
      const items = () => state.getIn(['timelines', timelineId, 'items']).toArray();

      arm();
      const stream = connectTimelineStream(timelineId, channel, params)(dispatch, () => state);

      stream.onDisconnect();
      stream.onConnect();
      await drain();
      stream.onReceive({ event: 'update', payload: JSON.stringify(body('100', '<p>LIVE</p>')) });
      releasePage(page);
      await drain();
      expect(pending()).toEqual(['110', '100', '90']);
      expect(items()).toEqual(['80', '70']);
      expect(state.getIn(['statuses', '100', 'content'])).toBe('<p>LIVE</p>');
      expect(state.getIn(['statuses', '110', 'content'])).toBe('<p>newer</p>');

      arm();
      state = state
        .setIn(['timelines', timelineId], fromJS({
          items: ['80', '70'],
          pendingItems: [],
          isLoading: false,
          hasMore: true,
          online: true,
          top: true,
        }))
        .set('statuses', ImmutableMap());
      const edited = connectTimelineStream(timelineId, channel, params)(dispatch, () => state);

      edited.onDisconnect();
      edited.onConnect();
      await drain();
      edited.onReceive({ event: 'update', payload: JSON.stringify(body('100', '<p>LIVE</p>')) });
      edited.onReceive({ event: 'status.update', payload: JSON.stringify(body('100', '<p>EDIT</p>')) });
      releasePage(page);
      await drain();
      expect(pending()).toEqual(['110', '100', '90']);
      expect(state.getIn(['statuses', '100', 'content'])).toBe('<p>EDIT</p>');

      arm();
      state = state
        .setIn(['timelines', timelineId], fromJS({
          items: ['80', '70'],
          pendingItems: [],
          isLoading: false,
          hasMore: true,
          online: true,
          top: true,
        }))
        .set('statuses', ImmutableMap());
      const removed = connectTimelineStream(timelineId, channel, params)(dispatch, () => state);

      removed.onDisconnect();
      removed.onConnect();
      await drain();
      removed.onReceive({ event: 'update', payload: JSON.stringify(body('100', '<p>LIVE</p>')) });
      removed.onReceive({ event: 'delete', payload: '100' });
      releasePage(page);
      await drain();
      expect(pending()).toEqual(['110', '90']);
      expect(pending()).not.toContain('100');
      expect(items()).toEqual(['80', '70']);
      expect(state.getIn(['statuses', '100'])).toBeUndefined();
      expect(state.getIn(['statuses', '90', 'content'])).toBe('<p>between</p>');
    }
  });
});
