jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));
jest.mock('../../stream', () => ({ connectStream: (channel, params, factory) => factory }));
jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: () => ({ refs: [] }),
}));

import { Map as ImmutableMap, fromJS } from 'immutable';

import api from '../../api';
import { connectTimelineStream } from '../streaming';
import {
  closeExternalFeedView,
  discardExternalFeedSessionForTests,
  openExternalFeedView,
  reconcileOpenExternalViews,
} from '../external_feeds';
import timelinesReducer from '../../reducers/timelines';
import statusesReducer from '../../reducers/statuses';
import accountsReducer from '../../reducers/accounts';
import relationshipsReducer from '../../reducers/relationships';

const drain = async () => {
  for (let step = 0; step < 30; step += 1) {
    await Promise.resolve();
  }
};

const account = (id = '2') => ({
  id,
  username: 'ada',
  acct: 'ada',
  display_name: 'Ada',
  note: '',
  url: 'https://example.test/@ada',
  emojis: [],
  followed_message: '',
});

const body = (id, content, extra = {}) => ({
  id,
  content,
  account: account(),
  created_at: '2020-01-01T00:00:00.000Z',
  visibility: 'public',
  emojis: [],
  media_attachments: [],
  ...extra,
});

const compact = (statuses, extra = {}) => ({
  status: 200,
  headers: {},
  data: {
    statuses,
    accounts: extra.accounts || [account()],
    referenced_statuses: extra.referenced_statuses || [],
    relationships: extra.relationships || [],
  },
});

const members = (ids) => ({
  status: 200,
  headers: {},
  data: {
    outcome: 'complete',
    results: (ids || []).map(id => ({ id, outcome: 'member' })),
  },
});

describe('external feed reconnect guard', () => {
  let state;
  let calls;

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

  const loaded = (items, extra = {}) => fromJS({
    items,
    pendingItems: [],
    isLoading: false,
    hasMore: true,
    online: true,
    ...extra,
  });

  const base = (timelines, statuses = ImmutableMap()) => ImmutableMap({
    meta: ImmutableMap({ locale: 'en', me: '1' }),
    externalFeeds: ImmutableMap({ permitted: false }),
    settings: ImmutableMap({ home: ImmutableMap({ shows: ImmutableMap() }) }),
    markers: ImmutableMap({ home: '9999' }),
    notifications: ImmutableMap(),
    timelines,
    statuses,
    accounts: ImmutableMap(),
    relationships: ImmutableMap(),
    polls: ImmutableMap(),
    filters: ImmutableMap(),
  });

  beforeEach(() => {
    calls = [];
    api.mockImplementation(() => ({
      get: (path, config) => {
        const params = (config && config.params) || {};

        calls.push({ path, params });

        if (path === '/api/v1/timelines/external_feed_capability') {
          return Promise.resolve({ status: 200, headers: {}, data: { permitted: state.getIn(['externalFeeds', 'permitted']) === true } });
        }

        return Promise.resolve({ status: 200, headers: {}, data: [] });
      },
      post: (path, payload) => {
        calls.push({ path, payload });
        return Promise.resolve(members(payload && payload.ids));
      },
    }));
    discardExternalFeedSessionForTests();
  });

  afterEach(() => {
    discardExternalFeedSessionForTests();
  });

  const homeItems = () => state.getIn(['timelines', 'home', 'items']).toArray();

  it('keeps since_id at the loaded id behind a disconnect gap', async () => {
    state = base(ImmutableMap({
      home: loaded(['80', '70']),
      'list:4': loaded(['15', '14']),
    }));
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);
    const list = connectTimelineStream('list:4', 'list', { list: '4' })(dispatch, () => state);

    home.onConnect();
    await drain();
    home.onDisconnect();
    expect(homeItems()[0]).toBe(null);
    calls.length = 0;
    home.onConnect();
    await drain();

    const recent = calls.find(call => call.path === '/api/v1/timelines/home' && call.params.since_id);

    expect(recent.params.since_id).toBe('80');
    expect(homeItems()[0]).toBe(null);

    list.onDisconnect();
    calls.length = 0;
    list.onConnect();
    await drain();
    expect(calls.find(call => call.path === '/api/v1/timelines/list/4' && call.params.since_id).params.since_id).toBe('15');
    expect(state.getIn(['timelines', 'list:4', 'items']).toArray()[0]).toBe(null);
  });

  it('leaves the gap when a reconnect page does not reach the loaded id', async () => {
    state = base(ImmutableMap({
      home: loaded(['80', '70']),
    }));
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    home.onDisconnect();
    api.mockImplementation(() => ({
      get: (path, config) => {
        const params = (config && config.params) || {};

        if (params.since_id) {
          return Promise.resolve(compact([
            body('100', '<p>newer</p>'),
            body('99', '<p>next</p>'),
          ]));
        }

        return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
      },
      post: () => Promise.resolve(members([])),
    }));
    home.onConnect();
    await drain();

    expect(homeItems()).toEqual(['100', '99', null, '80', '70']);
    expect(state.getIn(['timelines', 'home', 'hasMore'])).not.toBe(false);
  });

  it('does not close the gap on 206 or on a failed reconnect page', async () => {
    state = base(ImmutableMap({
      home: loaded(['80', '70']),
    }));
    const partial = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    partial.onDisconnect();
    api.mockImplementation(() => ({
      get: (path, config) => {
        if (config && config.params && config.params.since_id) {
          return Promise.resolve({ ...compact([body('100', '<p>partial</p>')]), status: 206 });
        }

        return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
      },
      post: () => Promise.resolve(members([])),
    }));
    partial.onConnect();
    await drain();
    expect(homeItems()).toEqual([null, '100', null, '80', '70']);

    state = base(ImmutableMap({
      home: loaded(['80', '70']),
    }));
    const failed = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    failed.onDisconnect();
    api.mockImplementation(() => ({
      get: (path, config) => {
        if (config && config.params && config.params.since_id) {
          return Promise.reject({ response: { status: 429 } });
        }

        return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
      },
      post: () => Promise.resolve(members([])),
    }));
    failed.onConnect();
    await drain();
    expect(homeItems()).toEqual([null, '80', '70']);
    expect(state.getIn(['timelines', 'home', 'isLoading'])).toBe(false);

    const interrupted = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    interrupted.onDisconnect();
    api.mockImplementation(() => ({
      get: (path, config) => {
        if (config && config.params && config.params.since_id) {
          return Promise.reject(new Error('socket closed'));
        }

        return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
      },
      post: () => Promise.resolve(members([])),
    }));
    interrupted.onConnect();
    await drain();
    expect(homeItems()).toEqual([null, '80', '70']);
  });

  const armHome = () => {
    let releasePage;

    api.mockImplementation(() => ({
      get: (path, config) => {
        const params = (config && config.params) || {};

        calls.push({ path, params });

        if (path === '/api/v1/timelines/external_feed_capability') {
          return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
        }

        if (params.since_id) {
          return new Promise(resolve => {
            releasePage = resolve;
          });
        }

        return Promise.resolve({ status: 200, headers: {}, data: [] });
      },
      post: (path, payload) => {
        calls.push({ path, payload });
        return Promise.resolve(members(payload && payload.ids));
      },
    }));

    return () => releasePage;
  };

  it('does not import a reconnect body after a stream edit or delete', async () => {
    state = base(ImmutableMap({
      home: loaded(['90', '80']),
    }));
    const releaseOf = armHome();
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    dispatch(openExternalFeedView('home', { targets: [{ type: 'home' }] }));
    home.onConnect();
    await drain();
    home.onDisconnect();
    home.onConnect();
    await drain();
    home.onReceive({
      event: 'status.update',
      payload: JSON.stringify(body('90', '<p>NEW</p>')),
    });
    releaseOf()(compact([
      body('95', '<p>fresh</p>'),
      body('90', '<p>OLD</p>'),
    ]));
    await drain();

    expect(state.getIn(['statuses', '90', 'content'])).toBe('<p>NEW</p>');
    expect(homeItems()).toEqual(expect.arrayContaining(['95', '90']));

    state = base(ImmutableMap({
      home: loaded(['90', '80']),
    }), ImmutableMap({
      '90': ImmutableMap({ id: '90', content: '<p>gone</p>', account: '2', visibility: 'public' }),
    }));
    const releaseDelete = armHome();
    const again = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    dispatch(openExternalFeedView('home', { targets: [{ type: 'home' }] }));
    again.onDisconnect();
    again.onConnect();
    await drain();
    again.onReceive({ event: 'delete', payload: '90' });
    releaseDelete()(compact([body('90', '<p>OLD</p>')]));
    await drain();

    expect(state.getIn(['statuses', '90'])).toBeUndefined();
    expect(homeItems()).not.toContain('90');
    expect(homeItems()[0]).toBe(null);
  });

  it('drops a reconnect page after a route change or a closed view', async () => {
    state = base(ImmutableMap({
      home: loaded(['80', '70']),
    }));
    const releaseOf = armHome();
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);
    const token = dispatch(openExternalFeedView('home', { targets: [{ type: 'home' }] }));

    home.onDisconnect();
    home.onConnect();
    await drain();
    home.onReceive({
      event: 'external_feed_changed',
      payload: {
        version: 1,
        reason: 'routes_updated',
        targets: [{ type: 'home' }],
        feed_routes_revision: '3',
        subscription_id: '1',
      },
    });
    releaseOf()(compact([body('95', '<p>late</p>')]));
    await drain();
    expect(homeItems()).toEqual([null, '80', '70']);

    const releaseClosed = armHome();
    const closed = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    closed.onDisconnect();
    closed.onConnect();
    await drain();
    dispatch(closeExternalFeedView('home', token));
    releaseClosed()(compact([body('96', '<p>closed</p>')]));
    await drain();
    expect(homeItems()).not.toContain('96');
    expect(state.getIn(['statuses', '96'])).toBeUndefined();
  });

  it('reads held ids again after reconnect and after the tab returns', async () => {
    state = base(ImmutableMap({
      home: loaded(['90']),
      'list:4': loaded(['15']),
    }), ImmutableMap({
      '90': ImmutableMap({ id: '90', visibility: 'external' }),
      '15': ImmutableMap({ id: '15', visibility: 'external' }),
    }));
    state = state.setIn(['externalFeeds', 'permitted'], true);
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);
    const list = connectTimelineStream('list:4', 'list', { list: '4' })(dispatch, () => state);

    dispatch(openExternalFeedView('home', { targets: [{ type: 'home' }] }));
    dispatch(openExternalFeedView('list:4', { targets: [{ type: 'list', id: '4' }] }));
    await drain();
    const memberships = () => calls.filter(call => call.path === '/api/v1/timelines/membership');
    const bodies = () => calls.filter(call => call.path === '/api/v1/statuses');
    const afterFirst = { memberships: memberships().length, bodies: bodies().length };

    expect(afterFirst.memberships).toBeGreaterThan(0);
    expect(afterFirst.bodies).toBeGreaterThan(0);
    dispatch(reconcileOpenExternalViews());
    await drain();
    expect(memberships().length).toBe(afterFirst.memberships);
    expect(bodies().length).toBe(afterFirst.bodies);

    home.onDisconnect();
    home.onConnect();
    await drain();
    expect(memberships().length).toBeGreaterThan(afterFirst.memberships);
    expect(bodies().length).toBeGreaterThan(afterFirst.bodies);
    expect(memberships().some(call => (call.payload.ids || []).indexOf('90') !== -1)).toBe(true);

    const afterHome = { memberships: memberships().length, bodies: bodies().length };

    list.onDisconnect();
    list.onConnect();
    await drain();
    expect(memberships().length).toBeGreaterThan(afterHome.memberships);
    expect(memberships().some(call => (call.payload.ids || []).indexOf('15') !== -1)).toBe(true);

    const afterList = bodies().length;

    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' });
    document.dispatchEvent(new Event('visibilitychange'));
    await drain();
    expect(bodies().length).toBeGreaterThan(afterList);
  });

  it('keeps a streamed id that sits between the remaining reconnect rows', async () => {
    const timelines = [
      ['home', 'user', {}],
      ['list:4', 'list', { list: '4' }],
    ];
    const page = compact([
      body('110', '<p>newer</p>'),
      body('100', '<p>OLD</p>'),
      body('90', '<p>between</p>'),
    ]);

    for (let index = 0; index < timelines.length; index += 1) {
      const [timelineId, channel, params] = timelines[index];
      const ids = () => state.getIn(['timelines', timelineId, 'items']).toArray();

      state = base(ImmutableMap({ [timelineId]: loaded(['80', '70']) }));
      const releaseUpdate = armHome();
      const stream = connectTimelineStream(timelineId, channel, params)(dispatch, () => state);

      stream.onDisconnect();
      stream.onConnect();
      await drain();
      stream.onReceive({ event: 'update', payload: JSON.stringify(body('100', '<p>LIVE</p>')) });
      releaseUpdate()(page);
      await drain();
      expect(ids()).toEqual(['110', '100', '90', null, '80', '70']);
      expect(state.getIn(['statuses', '100', 'content'])).toBe('<p>LIVE</p>');
      expect(state.getIn(['statuses', '110', 'content'])).toBe('<p>newer</p>');
      expect(state.getIn(['statuses', '90', 'content'])).toBe('<p>between</p>');

      state = base(ImmutableMap({ [timelineId]: loaded(['80', '70']) }));
      const releaseEdit = armHome();
      const edited = connectTimelineStream(timelineId, channel, params)(dispatch, () => state);

      edited.onDisconnect();
      edited.onConnect();
      await drain();
      edited.onReceive({ event: 'update', payload: JSON.stringify(body('100', '<p>LIVE</p>')) });
      edited.onReceive({ event: 'status.update', payload: JSON.stringify(body('100', '<p>EDIT</p>')) });
      releaseEdit()(page);
      await drain();
      expect(ids()).toEqual(['110', '100', '90', null, '80', '70']);
      expect(state.getIn(['statuses', '100', 'content'])).toBe('<p>EDIT</p>');

      state = base(ImmutableMap({ [timelineId]: loaded(['80', '70']) }));
      const releaseDelete = armHome();
      const removed = connectTimelineStream(timelineId, channel, params)(dispatch, () => state);

      removed.onDisconnect();
      removed.onConnect();
      await drain();
      removed.onReceive({ event: 'update', payload: JSON.stringify(body('100', '<p>LIVE</p>')) });
      removed.onReceive({ event: 'delete', payload: '100' });
      releaseDelete()(page);
      await drain();
      expect(ids()).toEqual(['110', '90', null, '80', '70']);
      expect(state.getIn(['statuses', '100'])).toBeUndefined();
      expect(state.getIn(['statuses', '90', 'content'])).toBe('<p>between</p>');
    }
  });

  it('fills a quiet reconnect when no home view is open', async () => {
    state = base(ImmutableMap({ home: loaded(['80', '70']) }));
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    home.onDisconnect();
    api.mockImplementation(() => ({
      get: (path, config) => {
        if (config && config.params && config.params.since_id) {
          return Promise.resolve(compact([body('100', '<p>quiet</p>')]));
        }

        return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
      },
      post: () => Promise.resolve(members([])),
    }));
    home.onConnect();
    await drain();
    expect(homeItems()).toEqual(['100', null, '80', '70']);
    expect(state.getIn(['statuses', '100', 'content'])).toBe('<p>quiet</p>');
  });

  it('does not apply a reconnect page that started with no view after the route changes', async () => {
    state = base(ImmutableMap({
      home: loaded(['80', '70']),
      'list:4': loaded(['15', '14']),
    }));
    const releaseHome = armHome();
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);
    const routeHome = {
      event: 'external_feed_changed',
      payload: {
        version: 1,
        reason: 'routes_updated',
        targets: [{ type: 'home' }],
        feed_routes_revision: '4',
        subscription_id: '1',
      },
    };

    home.onDisconnect();
    home.onConnect();
    await drain();
    home.onReceive(routeHome);
    releaseHome()(compact([body('95', '<p>removed</p>')]));
    await drain();
    expect(homeItems()).toEqual([null, '80', '70']);
    expect(state.getIn(['statuses', '95'])).toBeUndefined();

    const releaseMounted = armHome();
    const mounted = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    mounted.onDisconnect();
    mounted.onConnect();
    await drain();
    mounted.onReceive(routeHome);
    dispatch(openExternalFeedView('home', { targets: [{ type: 'home' }] }));
    await drain();
    releaseMounted()(compact([body('94', '<p>after mount</p>')]));
    await drain();
    expect(homeItems()).not.toContain('94');
    expect(state.getIn(['statuses', '94'])).toBeUndefined();

    const releaseList = armHome();
    const list = connectTimelineStream('list:4', 'list', { list: '4' })(dispatch, () => state);

    list.onDisconnect();
    list.onConnect();
    await drain();
    list.onReceive({
      event: 'external_feed_changed',
      payload: {
        version: 1,
        reason: 'routes_updated',
        targets: [{ type: 'list', id: '4' }],
        feed_routes_revision: '5',
        subscription_id: '1',
      },
    });
    releaseList()(compact([body('16', '<p>removed</p>')]));
    await drain();
    dispatch(openExternalFeedView('list:4', { targets: [{ type: 'list', id: '4' }] }));
    await drain();
    expect(state.getIn(['timelines', 'list:4', 'items']).toArray()).toEqual([null, '15', '14']);
    expect(state.getIn(['statuses', '16'])).toBeUndefined();
  });

  it('drops a reconnect page when the feed is turned off before home is mounted', async () => {
    state = base(ImmutableMap({ home: loaded(['80', '70']) })).setIn(['externalFeeds', 'permitted'], true);
    let releasePage;

    api.mockImplementation(() => ({
      get: (path, config) => {
        const params = (config && config.params) || {};

        if (path === '/api/v1/timelines/external_feed_capability') {
          return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
        }

        if (params.since_id) {
          return new Promise(resolve => {
            releasePage = resolve;
          });
        }

        return Promise.resolve({ status: 200, headers: {}, data: [] });
      },
      post: () => Promise.resolve(members([])),
    }));
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    home.onDisconnect();
    home.onConnect();
    await drain();
    releasePage(compact([body('95', '<p>stale</p>')]));
    await drain();
    expect(homeItems()).toEqual([null, '80', '70']);
    expect(state.getIn(['statuses', '95'])).toBeUndefined();

    let releaseMounted;

    api.mockImplementation(() => ({
      get: (path, config) => {
        const params = (config && config.params) || {};

        if (path === '/api/v1/timelines/external_feed_capability') {
          return Promise.resolve({ status: 200, headers: {}, data: { permitted: false } });
        }

        if (params.since_id) {
          return new Promise(resolve => {
            releaseMounted = resolve;
          });
        }

        return Promise.resolve({ status: 200, headers: {}, data: [] });
      },
      post: () => Promise.resolve(members([])),
    }));
    const mounted = connectTimelineStream('home', 'user', {})(dispatch, () => state);

    mounted.onDisconnect();
    mounted.onConnect();
    await drain();
    dispatch(openExternalFeedView('home', { targets: [{ type: 'home' }] }));
    await drain();
    releaseMounted(compact([body('96', '<p>after mount</p>')]));
    await drain();
    expect(homeItems()).not.toContain('96');
    expect(state.getIn(['statuses', '96'])).toBeUndefined();
  });

  it('drops a loading reconnect page when streaming reconnects again and then catches up', async () => {
    state = base(ImmutableMap({
      home: loaded(['80', '70']),
      'list:4': loaded(['15', '14']),
    }));
    const releaseHome = armHome();
    const home = connectTimelineStream('home', 'user', {})(dispatch, () => state);
    const homeSince = () => calls.filter(call => call.path === '/api/v1/timelines/home' && call.params.since_id);

    home.onDisconnect();
    home.onConnect();
    await drain();
    expect(state.getIn(['timelines', 'home', 'isLoading'])).toBe(true);
    expect(homeSince()).toHaveLength(1);
    home.onDisconnect();
    home.onConnect();
    await drain();
    expect(state.getIn(['timelines', 'home', 'isLoading'])).toBe(true);
    expect(homeSince()).toHaveLength(1);
    expect(state.getIn(['externalFeeds', 'permitted'])).toBe(false);
    releaseHome()(compact([body('95', '<p>stale</p>')]));
    await drain();
    expect(homeItems()).toEqual([null, '80', '70']);
    expect(state.getIn(['statuses', '95'])).toBeUndefined();
    expect(homeSince()).toHaveLength(2);
    expect(state.getIn(['timelines', 'home', 'isLoading'])).toBe(true);
    releaseHome()(compact([body('96', '<p>current</p>')]));
    await drain();
    expect(homeItems()).toEqual(['96', null, '80', '70']);
    expect(state.getIn(['statuses', '96', 'content'])).toBe('<p>current</p>');
    expect(state.getIn(['statuses', '95'])).toBeUndefined();

    calls.length = 0;
    const releaseList = armHome();
    const list = connectTimelineStream('list:4', 'list', { list: '4' })(dispatch, () => state);
    const listSince = () => calls.filter(call => call.path === '/api/v1/timelines/list/4' && call.params.since_id);

    list.onDisconnect();
    list.onConnect();
    await drain();
    expect(state.getIn(['timelines', 'list:4', 'isLoading'])).toBe(true);
    list.onDisconnect();
    list.onConnect();
    await drain();
    expect(listSince()).toHaveLength(1);
    releaseList()(compact([body('16', '<p>stale</p>')]));
    await drain();
    expect(state.getIn(['timelines', 'list:4', 'items']).toArray()).toEqual([null, '15', '14']);
    expect(state.getIn(['statuses', '16'])).toBeUndefined();
    expect(listSince()).toHaveLength(2);
    releaseList()(compact([body('17', '<p>current</p>')]));
    await drain();
    expect(state.getIn(['timelines', 'list:4', 'items']).toArray()).toEqual(['17', null, '15', '14']);
    expect(state.getIn(['statuses', '17', 'content'])).toBe('<p>current</p>');
    expect(state.getIn(['statuses', '16'])).toBeUndefined();
  });
});
