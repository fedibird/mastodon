jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));

const mockConnect = jest.fn();

jest.mock('../../stream', () => ({
  connectStream: (...args) => mockConnect(...args),
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: () => ({ refs: [] }),
}));

import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';

import api from '../../api';
import { normalizeSource, sourceKey } from '../../mix/source';
import { mixTimelineView } from '../../mix/view';
import { externalFeedSession } from '../../external_feeds/session';
import { noteExternalStatusStream, discardExternalFeedSessionForTests, openExternalFeedView } from '../external_feeds';
import { openMixStream, resetMixStreams } from '../mix_streaming';
import { importFetchedStatus } from '../importer';
import mixTimelines from '../../reducers/mix_timelines';
import statusesReducer from '../../reducers/statuses';
import accountsReducer from '../../reducers/accounts';
import relationshipsReducer from '../../reducers/relationships';
import { MIX_EXTERNAL_RECONCILE, MIX_SOURCE_SUCCESS, MIX_TIMELINE_OPEN } from '../mix_timelines';

const drain = async () => {
  for (let step = 0; step < 40; step += 1) {
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

const status = (id, content, extra = {}) => ({
  id,
  content,
  account: extra.account || account(),
  created_at: '2020-01-01T00:00:00.000Z',
  visibility: 'public',
  emojis: [],
  media_attachments: [],
  ...extra,
});

const listSource = normalizeSource({ type: 'list', id: '4', params: {} }).source;
const listKey = sourceKey(listSource);

const sourceEntry = (ids) => ImmutableMap({
  ids: ImmutableList(ids),
  descriptor: fromJS(listSource),
  loaded: true,
  hasMore: false,
  gap: false,
  partial: false,
  filterResults: ImmutableMap(),
});

describe('mix external pane reconcile', () => {
  let state;
  const connections = [];

  const apply = (action) => {
    state = state
      .set('mix_timelines', mixTimelines(state.get('mix_timelines'), action))
      .set('statuses', statusesReducer(state.get('statuses'), action))
      .set('accounts', accountsReducer(state.get('accounts'), action))
      .set('relationships', relationshipsReducer(state.get('relationships'), action));
  };

  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    apply(action);
    return action;
  };

  beforeEach(() => {
    connections.length = 0;
    resetMixStreams();
    discardExternalFeedSessionForTests();
    mockConnect.mockImplementation((channel, params, factory) => (innerDispatch, getState) => {
      const handlers = factory(innerDispatch, getState);

      connections.push({ channel, params, handlers });
      return () => {};
    });
    state = ImmutableMap({
      meta: ImmutableMap({ me: '1', locale: 'en' }),
      externalFeeds: ImmutableMap({ permitted: true }),
      settings: ImmutableMap({
        mixes: ImmutableList([fromJS({
          id: 'm1',
          version: 1,
          title: 'Desk',
          sources: [listSource],
        })]),
      }),
      relationships: ImmutableMap(),
      accounts: ImmutableMap(),
      statuses: ImmutableMap(),
      polls: ImmutableMap(),
      filters: ImmutableMap(),
      mix_timelines: ImmutableMap(),
    });
  });

  afterEach(() => {
    discardExternalFeedSessionForTests();
  });

  const column = (extra) => ImmutableMap({
    mixId: 'm1',
    sessionId: 's',
    definitionFingerprint: 'fp',
    displayMode: 'live',
    deletedStatusIds: ImmutableList(),
    pendingStatusIds: ImmutableList(),
    sources: ImmutableMap({ [listKey]: sourceEntry(['100']) }),
    live: ImmutableMap({
      [listKey]: ImmutableMap({ statusIds: ImmutableList(['100']), ids: ImmutableList(['100']) }),
    }),
    ...extra,
  });

  it('imports a compact history page onto the history pane only', async () => {
    let release;
    const posts = [];

    api.mockImplementation(() => ({
      post: (path, payload) => {
        posts.push(payload && payload.ids);
        return Promise.resolve({
          status: 200,
          headers: {},
          data: { outcome: 'complete', results: (payload.ids || []).map(id => ({ id, outcome: 'member' })) },
        });
      },
      get: (path, config) => {
        const maxId = config && config.params && config.params.max_id;

        if (maxId === '50') {
          return new Promise(resolve => {
            release = resolve;
          });
        }

        if (path === '/api/v1/statuses') {
          return Promise.resolve({ status: 200, headers: {}, data: [] });
        }

        return Promise.resolve({ status: 200, headers: {}, data: [] });
      },
    }));

    state = state.setIn(['mix_timelines', 'col'], column({
      split: ImmutableMap({
        id: 'split-1',
        history: ImmutableMap({
          sources: ImmutableMap({ [listKey]: sourceEntry(['50', '40']) }),
          frozenLive: ImmutableMap({
            [listKey]: ImmutableMap({ statusIds: ImmutableList(['100']), ids: ImmutableList(['100']) }),
          }),
        }),
      }),
    }));
    dispatch(importFetchedStatus(status('3', '<p>NEW</p>')));
    dispatch(openExternalFeedView('mix:col', { targets: [{ type: 'list', id: '4' }] }));
    await drain();
    noteExternalStatusStream('3');
    release({
      status: 200,
      headers: {},
      data: {
        statuses: [{
          id: '45',
          content: '<p>history</p>',
          account: '2',
          reblog: '3',
          visibility: 'public',
          emojis: [],
          media_attachments: [],
          created_at: '2020-01-01T00:00:00.000Z',
        }],
        accounts: [account('2')],
        referenced_statuses: [status('3', '<p>OLD</p>')],
        relationships: [{ id: '2', following: false }],
      },
    });
    await drain();

    const timeline = state.getIn(['mix_timelines', 'col']);
    const live = mixTimelineView(timeline, state.get('statuses'), null, '1', 'live');
    const history = mixTimelineView(timeline, state.get('statuses'), null, '1', 'history');

    expect(timeline.getIn(['sources', listKey, 'ids']).toArray()).toEqual(['100']);
    expect(timeline.getIn(['live', listKey, 'statusIds']).toArray()).toEqual(['100']);
    expect(timeline.getIn(['split', 'history', 'frozenLive', listKey, 'statusIds']).toArray()).toEqual(['100']);
    expect(timeline.getIn(['split', 'history', 'sources', listKey, 'ids']).toArray()).toEqual(['50', '45', '40']);
    expect(live.statusIds.toArray()).not.toContain('45');
    expect(history.statusIds.toArray()).toEqual(expect.arrayContaining(['50', '45', '40']));
    expect(state.getIn(['accounts', '2', 'acct'])).toBe('ada');
    expect(state.getIn(['statuses', '45', 'reblog'])).toBe('3');
    expect(state.getIn(['statuses', '3', 'content'])).toBe('<p>NEW</p>');
    expect(state.getIn(['relationships', '2', 'following'])).toBe(false);
    expect(posts.some(ids => ids.indexOf('100') !== -1)).toBe(true);
  });

  it('seeds an empty live source without creating history', async () => {
    api.mockImplementation(() => ({
      post: (path, payload) => Promise.resolve({
        status: 200,
        headers: {},
        data: { outcome: 'complete', results: (payload.ids || []).map(id => ({ id, outcome: 'member' })) },
      }),
      get: () => Promise.resolve({
        status: 200,
        headers: {},
        data: [status('45', '<p>seed</p>')],
      }),
    }));
    state = state.setIn(['mix_timelines', 'col'], column().setIn(['sources', listKey, 'ids'], ImmutableList()));
    dispatch(openExternalFeedView('mix:col', { targets: [{ type: 'list', id: '4' }] }));
    await drain();

    const timeline = state.getIn(['mix_timelines', 'col']);

    expect(timeline.getIn(['sources', listKey, 'ids']).toArray()).toEqual(['45']);
    expect(timeline.get('split')).toBeUndefined();
    expect(mixTimelineView(timeline, state.get('statuses'), null, '1', 'live').statusIds.toArray()).toContain('45');
    expect(state.getIn(['accounts', '2', 'username'])).toBe('ada');
    expect(state.getIn(['statuses', '45', 'content'])).toBe('<p>seed</p>');
  });

  it('does not apply a history page after the split is replaced', async () => {
    let release;

    api.mockImplementation(() => ({
      post: (path, payload) => Promise.resolve({
        status: 200,
        headers: {},
        data: { outcome: 'complete', results: (payload.ids || []).map(id => ({ id, outcome: 'member' })) },
      }),
      get: (path, config) => {
        const maxId = config && config.params && config.params.max_id;

        if (maxId === '50') {
          return new Promise(resolve => {
            release = resolve;
          });
        }

        return Promise.resolve({ status: 200, headers: {}, data: [] });
      },
    }));
    state = state.setIn(['mix_timelines', 'col'], column({
      split: ImmutableMap({
        id: 'split-1',
        history: ImmutableMap({
          sources: ImmutableMap({ [listKey]: sourceEntry(['50', '40']) }),
        }),
      }),
    }));
    dispatch(openExternalFeedView('mix:col', { targets: [{ type: 'list', id: '4' }] }));
    await drain();
    state = state.setIn(['mix_timelines', 'col', 'split', 'id'], 'split-2');
    release({
      status: 200,
      headers: {},
      data: [status('45', '<p>late</p>')],
    });
    await drain();

    expect(state.getIn(['mix_timelines', 'col', 'split', 'history', 'sources', listKey, 'ids']).toArray()).toEqual(['50', '40']);
    expect(state.getIn(['mix_timelines', 'col', 'sources', listKey, 'ids']).toArray()).toEqual(['100']);
  });

  it('still removes an id from every copy of that source', () => {
    state = state.setIn(['mix_timelines', 'col'], column({
      split: ImmutableMap({
        id: 'split-1',
        history: ImmutableMap({
          sources: ImmutableMap({ [listKey]: sourceEntry(['100', '40']) }),
          frozenLive: ImmutableMap({
            [listKey]: ImmutableMap({ statusIds: ImmutableList(['100']) }),
          }),
        }),
      }),
    }));
    apply({
      type: MIX_EXTERNAL_RECONCILE,
      columnKey: 'col',
      sourceKey: listKey,
      sessionId: 's',
      definitionFingerprint: 'fp',
      removeIds: ['100'],
    });

    const timeline = state.getIn(['mix_timelines', 'col']);

    expect(timeline.getIn(['sources', listKey, 'ids']).toArray()).toEqual([]);
    expect(timeline.getIn(['live', listKey, 'statusIds']).toArray()).toEqual([]);
    expect(timeline.getIn(['split', 'history', 'sources', listKey, 'ids']).toArray()).toEqual(['40']);
    expect(timeline.getIn(['split', 'history', 'frozenLive', listKey, 'statusIds']).toArray()).toEqual([]);
  });

  it('asks again for a held mix id when that mix socket reconnects', async () => {
    const posts = [];

    api.mockImplementation(() => ({
      post: (path, payload) => {
        if (path === '/api/v1/timelines/membership') {
          posts.push((payload && payload.ids) || []);
        }

        return Promise.resolve({
          status: 200,
          headers: {},
          data: { outcome: 'complete', results: ((payload && payload.ids) || []).map(id => ({ id, outcome: 'member' })) },
        });
      },
      get: (path) => {
        if (path === '/api/v1/statuses') {
          return Promise.resolve({
            status: 200,
            headers: {},
            data: [{ id: '100', content: '<p>held</p>', visibility: 'external', account: account() }],
          });
        }

        return Promise.resolve({ status: 200, headers: {}, data: [] });
      },
    }));
    dispatch({
      type: MIX_TIMELINE_OPEN,
      columnKey: 'col',
      mixId: 'm1',
      sessionId: 's',
      definitionFingerprint: 'fp',
      sources: [{ key: listKey, descriptor: listSource }],
    });
    state = state.setIn(['statuses', '100'], ImmutableMap({ id: '100', visibility: 'external' }));
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'col',
      sourceKey: listKey,
      sessionId: 's',
      definitionFingerprint: 'fp',
      ids: ['100'],
      partial: false,
    });
    dispatch(openMixStream('col', state.getIn(['settings', 'mixes', 0])));
    externalFeedSession.open('mix:col', { targets: [{ type: 'list', id: '4' }] });
    const listStream = connections.find(row => row.channel === 'list');

    listStream.handlers.onConnect();
    await drain();
    const first = posts.length;

    expect(first).toBeGreaterThan(0);
    listStream.handlers.onDisconnect();
    listStream.handlers.onConnect();
    await drain();
    expect(posts.length).toBeGreaterThan(first);
    expect(posts[posts.length - 1]).toContain('100');
  });
});
