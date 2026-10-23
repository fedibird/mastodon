jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));
jest.mock('../../stream', () => ({ connectStream: (channel, params, factory) => factory }));
jest.mock('../../api', () => ({ __esModule: true, default: jest.fn(), getLinks: () => ({ refs: [] }) }));

import { fromJS } from 'immutable';

import api from '../../api';
import { connectTimelineStream } from '../streaming';

describe('external feed reconnect', () => {
  it('fills since_id after a disconnect that never starts fallback polling', () => {
    const calls = [];

    api.mockImplementation(() => ({
      get: (path, config) => {
        calls.push({ path, params: config && config.params });
        return Promise.resolve({ status: 200, data: [], headers: {} });
      },
      post: () => Promise.resolve({ status: 200, data: { outcome: 'complete', results: [] } }),
    }));

    const state = fromJS({
      meta: { locale: 'en' },
      externalFeeds: { permitted: false },
      settings: { home: { shows: {} } },
      timelines: {
        home: { items: ['40', '30'], pendingItems: [] },
        'list:4': { items: ['15'], pendingItems: [] },
      },
      statuses: {},
    });
    const dispatch = (action) => (typeof action === 'function' ? action(dispatch, () => state) : action);
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    home.onConnect();
    expect(calls.some(call => call.path === '/api/v1/timelines/home' && call.params && call.params.since_id)).toBe(false);
    home.onDisconnect();
    home.onConnect();
    expect(calls.find(call => call.path === '/api/v1/timelines/home' && call.params && call.params.since_id).params.since_id).toBe('40');

    const list = connectTimelineStream('list:4', 'list', { list: '4' })(dispatch, () => state);

    list.onDisconnect();
    list.onConnect();
    expect(calls.find(call => call.path === '/api/v1/timelines/list/4' && call.params && call.params.since_id).params.since_id).toBe('15');
  });
});
