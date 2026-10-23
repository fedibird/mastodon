const flags = {
  hideDirectFromTimeline: false,
  hidePersonalFromTimeline: false,
  enableLimitedTimeline: true,
};

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../initial_state', () => ({
  get me () {
    return '1';
  },
  get enableLimitedTimeline () {
    return flags.enableLimitedTimeline;
  },
  get hideDirectFromTimeline () {
    return flags.hideDirectFromTimeline;
  },
  get hidePersonalFromTimeline () {
    return flags.hidePersonalFromTimeline;
  },
  get isAdministrator () {
    return false;
  },
  get new_features_policy () {
    return 'tester';
  },
  get maxFrequentlyUsedEmojis () {
    return 0;
  },
}));

jest.mock('../../api', () => jest.fn());

jest.mock('../importer', () => ({
  importFetchedStatuses: (statuses) => ({ type: 'STATUSES_IMPORT', statuses }),
}));

import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';

import api from '../../api';
import { resolveRequest } from '../../mix/adapter';
import { normalizeSource, sourceKey } from '../../mix/source';
import { externalFeedSession } from '../../external_feeds/session';
import { discardExternalFeedSessionForTests, noteExternalStatusStream, receiveExternalFeedChanged } from '../external_feeds';
import { TIMELINE_EXTERNAL_RECONCILE } from '../timelines';
import mixTimelines from '../../reducers/mix_timelines';
import { MIX_EXTERNAL_RECONCILE } from '../mix_timelines';

const homeSource = normalizeSource({
  type: 'home',
  params: {
    shows: {
      reblog: true,
      reply: true,
      private: true,
      limited: true,
      direct: true,
      personal: true,
      external: true,
    },
  },
}).source;
const homeKey = sourceKey(homeSource);

const members = (ids) => ({
  status: 200,
  data: {
    outcome: 'complete',
    results: ids.map(id => ({ id, outcome: 'member' })),
  },
});

const drain = async () => {
  for (let step = 0; step < 40; step += 1) {
    await Promise.resolve();
  }
};

const harness = (state) => {
  const actions = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    actions.push(action);
    return action;
  };

  return { actions, dispatch };
};

describe('external feed review regressions', () => {
  let post;
  let get;

  beforeEach(() => {
    flags.hideDirectFromTimeline = false;
    flags.hidePersonalFromTimeline = false;
    post = jest.fn((path, body) => Promise.resolve(members(body.ids || [])));
    get = jest.fn(() => Promise.resolve({ status: 200, data: [] }));
    api.mockImplementation(() => ({ post, get }));
    discardExternalFeedSessionForTests();
  });

  afterEach(() => {
    jest.useRealTimers();
    discardExternalFeedSessionForTests();
  });

  const openHome = (state) => {
    const { actions, dispatch } = harness(state);

    externalFeedSession.open('home', { targets: [{ type: 'home' }] });
    dispatch(receiveExternalFeedChanged({
      version: 1,
      reason: 'routes_updated',
      targets: [{ type: 'home' }],
      feed_routes_revision: '4',
      subscription_id: '9',
    }));
    return { actions, dispatch };
  };

  it('checks the held tail on the next cycle', async () => {
    jest.useFakeTimers();
    const ids = Array.from({ length: 201 }, (_value, index) => String(index + 1));
    const state = ImmutableMap({
      externalFeeds: ImmutableMap({ permitted: true }),
      timelines: ImmutableMap({
        home: ImmutableMap({
          items: ImmutableList(ids),
          pendingItems: ImmutableList(),
        }),
      }),
      statuses: ImmutableMap(),
      settings: ImmutableMap({ home: ImmutableMap({ shows: ImmutableMap() }) }),
      mix_timelines: ImmutableMap(),
    });

    openHome(state);
    await drain();
    const first = post.mock.calls.filter(call => call[0] === '/api/v1/timelines/membership').flatMap(call => call[1].ids);

    expect(first).toHaveLength(200);
    expect(first).not.toContain('201');

    jest.advanceTimersByTime(2000);
    await drain();
    const all = post.mock.calls.filter(call => call[0] === '/api/v1/timelines/membership').flatMap(call => call[1].ids);

    expect(all).toContain('201');
    expect(new Set(all).size).toBe(201);
    const settled = post.mock.calls.length;

    jest.advanceTimersByTime(2000);
    await drain();
    expect(post.mock.calls.length).toBe(settled);
  });

  it('resumes membership after a 429 without repeating a confirmed batch', async () => {
    jest.useFakeTimers();
    const ids = Array.from({ length: 60 }, (_value, index) => String(index + 1));
    let calls = 0;

    post.mockImplementation((_path, body) => {
      calls += 1;

      if (calls === 2) {
        return Promise.reject({ response: { status: 429 } });
      }

      return Promise.resolve(members(body.ids || []));
    });
    const state = ImmutableMap({
      externalFeeds: ImmutableMap({ permitted: false }),
      timelines: ImmutableMap({
        home: ImmutableMap({
          items: ImmutableList(ids),
          pendingItems: ImmutableList(),
        }),
      }),
      statuses: ImmutableMap(),
      settings: ImmutableMap({ home: ImmutableMap({ shows: ImmutableMap() }) }),
      mix_timelines: ImmutableMap(),
    });

    openHome(state);
    await drain();
    jest.advanceTimersByTime(2000);
    await drain();
    const posted = post.mock.calls.filter(call => call[0] === '/api/v1/timelines/membership').flatMap(call => call[1].ids);

    expect(posted.filter(id => Number(id) <= 50).length).toBe(50);
    expect(posted).toContain('60');
    expect(posted.filter(id => id === '1').length).toBe(1);
  });

  it('fetches the 81st external body on the next cycle', async () => {
    jest.useFakeTimers();
    const ids = Array.from({ length: 81 }, (_value, index) => String(index + 1));
    const statuses = {};

    ids.forEach(id => {
      statuses[id] = ImmutableMap({ visibility: 'external' });
    });
    const state = ImmutableMap({
      externalFeeds: ImmutableMap({ permitted: true }),
      timelines: ImmutableMap({
        home: ImmutableMap({
          items: ImmutableList(ids),
          pendingItems: ImmutableList(),
        }),
      }),
      statuses: ImmutableMap(statuses),
      settings: ImmutableMap({ home: ImmutableMap({ shows: ImmutableMap() }) }),
      mix_timelines: ImmutableMap(),
    });
    const fetched = [];

    get.mockImplementation((path, config) => {
      if (path === '/api/v1/statuses') {
        fetched.push((config.params.id || []).slice());
      }

      return Promise.resolve({ status: 200, data: [] });
    });

    openHome(state);
    await drain();
    expect(fetched.flat()).toHaveLength(80);
    expect(fetched.flat()).not.toContain('81');

    jest.advanceTimersByTime(2000);
    await drain();
    expect(fetched.flat()).toContain('81');
    const settled = get.mock.calls.length;

    jest.advanceTimersByTime(2000);
    await drain();
    expect(get.mock.calls.length).toBe(settled);
  });

  it('restores a previously streamed id when nothing moves during the history request', async () => {
    noteExternalStatusStream('90');
    const state = ImmutableMap({
      externalFeeds: ImmutableMap({ permitted: true }),
      timelines: ImmutableMap({
        home: ImmutableMap({
          items: ImmutableList(['100', '80']),
          pendingItems: ImmutableList(),
        }),
      }),
      statuses: ImmutableMap(),
      settings: ImmutableMap({ home: ImmutableMap({ shows: ImmutableMap() }) }),
      mix_timelines: ImmutableMap(),
    });

    get.mockImplementation((path) => {
      if (String(path).indexOf('/api/v1/timelines/home') === 0) {
        return Promise.resolve({
          status: 200,
          data: [{ id: '90', visibility: 'direct', visibility_ex: 'external' }],
        });
      }

      return Promise.resolve({ status: 200, data: [] });
    });
    const { actions } = openHome(state);

    await drain();
    const imported = actions.filter(action => action.type === 'STATUSES_IMPORT').flatMap(action => action.statuses.map(status => String(status.id)));
    const inserted = actions.filter(action => action.type === TIMELINE_EXTERNAL_RECONCILE).flatMap(action => action.insertIds || []);

    expect(imported).toContain('90');
    expect(inserted).toContain('90');
  });

  it('does not import a mix history body after a stream edit or delete', async () => {
    const column = ImmutableMap({
      mixId: 'm1',
      sessionId: 1,
      definitionFingerprint: 'fp',
      sources: ImmutableMap({
        [homeKey]: ImmutableMap({ ids: ImmutableList(['100', '80']) }),
      }),
    });
    const state = ImmutableMap({
      externalFeeds: ImmutableMap({ permitted: true }),
      timelines: ImmutableMap(),
      statuses: ImmutableMap(),
      settings: ImmutableMap({
        home: ImmutableMap({ shows: ImmutableMap() }),
        mixes: ImmutableList([fromJS({
          id: 'm1',
          version: 1,
          title: 'Desk',
          sources: [homeSource],
        })]),
      }),
      mix_timelines: ImmutableMap({ col: column }),
      meta: ImmutableMap({ me: '1' }),
    });
    let release;

    get.mockImplementation((path) => {
      if (String(path).indexOf('/api/v1/timelines/home') === 0) {
        return new Promise(resolve => {
          release = resolve;
        });
      }

      return Promise.resolve({ status: 200, data: [] });
    });
    const { actions, dispatch } = harness(state);

    externalFeedSession.open('mix:col', { targets: [{ type: 'home' }] });
    dispatch(receiveExternalFeedChanged({
      version: 1,
      reason: 'routes_updated',
      targets: [{ type: 'home' }],
      feed_routes_revision: '4',
      subscription_id: '9',
    }));
    await drain();
    noteExternalStatusStream('90');
    release({
      status: 200,
      data: [{ id: '90', content: '<p>old</p>', visibility: 'direct', visibility_ex: 'external', account: { id: '1' } }],
    });
    await drain();

    const imported = actions.filter(action => action.type === 'STATUSES_IMPORT').flatMap(action => (action.statuses || []).map(status => String(status.id)));
    const inserted = actions.filter(action => action.type === MIX_EXTERNAL_RECONCILE).flatMap(action => action.insertIds || []);

    expect(imported).not.toContain('90');
    expect(inserted).not.toContain('90');
  });

  it('requests a page for an empty home and for a distant history window', async () => {
    const state = ImmutableMap({
      externalFeeds: ImmutableMap({ permitted: true }),
      timelines: ImmutableMap({
        home: ImmutableMap({
          items: ImmutableList(),
          pendingItems: ImmutableList(),
          splitTimelineId: 'home:split:1',
        }),
        'home:split:1': ImmutableMap({
          items: ImmutableList(['100', '80']),
          pendingItems: ImmutableList(),
        }),
      }),
      statuses: ImmutableMap(),
      settings: ImmutableMap({ home: ImmutableMap({ shows: ImmutableMap() }) }),
      mix_timelines: ImmutableMap(),
    });
    const queries = [];

    get.mockImplementation((path, config) => {
      if (String(path).indexOf('/api/v1/timelines/home') === 0) {
        queries.push(config.params);
      }

      return Promise.resolve({ status: 200, data: [] });
    });
    openHome(state);
    await drain();

    expect(queries.length).toBeGreaterThan(0);
    expect(queries.some(params => params.max_id === '100')).toBe(true);
  });

  it('asks mix history for the same visibilities as resolveRequest', async () => {
    flags.hideDirectFromTimeline = true;
    flags.hidePersonalFromTimeline = true;
    const column = ImmutableMap({
      mixId: 'm1',
      sessionId: 1,
      definitionFingerprint: 'fp',
      sources: ImmutableMap({
        [homeKey]: ImmutableMap({ ids: ImmutableList(['100', '80']) }),
      }),
    });
    let state = ImmutableMap({
      externalFeeds: ImmutableMap({ permitted: true }),
      timelines: ImmutableMap(),
      statuses: ImmutableMap(),
      settings: ImmutableMap({
        home: ImmutableMap({ shows: ImmutableMap() }),
        mixes: ImmutableList([fromJS({
          id: 'm1',
          version: 1,
          title: 'Desk',
          sources: [homeSource],
        })]),
      }),
      mix_timelines: ImmutableMap({ col: column }),
      meta: ImmutableMap({ me: '1' }),
    });
    const expected = resolveRequest(homeSource, '100', { externalFeedsPermitted: true }).params.visibilities;

    get.mockImplementation(() => Promise.resolve({
      status: 200,
      data: [
        { id: '90', visibility: 'direct', visibility_ex: 'external', account: { id: '1' } },
        { id: '85', visibility: 'direct', account: { id: '2' } },
      ],
    }));
    const actions = [];
    const dispatch = (action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => state);
      }

      if (action.type === MIX_EXTERNAL_RECONCILE) {
        state = state.set('mix_timelines', mixTimelines(state.get('mix_timelines'), action));
      }

      actions.push(action);
      return action;
    };

    externalFeedSession.open('mix:col', { targets: [{ type: 'home' }] });
    dispatch(receiveExternalFeedChanged({
      version: 1,
      reason: 'routes_updated',
      targets: [{ type: 'home' }],
      feed_routes_revision: '4',
      subscription_id: '9',
    }));
    await drain();

    const historyCall = get.mock.calls.find(call => String(call[0]).indexOf('/api/v1/timelines/home') === 0);

    expect(expected).toEqual(expect.arrayContaining(['public', 'unlisted', 'private', 'limited', 'external']));
    expect(expected).not.toEqual(expect.arrayContaining(['direct', 'personal']));
    expect(historyCall[1].params.visibilities).toEqual(expected);
    expect(actions.filter(action => action.type === 'STATUSES_IMPORT').flatMap(action => action.statuses.map(status => String(status.id)))).toEqual(['90']);
    expect(state.getIn(['mix_timelines', 'col', 'sources', homeKey, 'ids']).toArray()).toEqual(['100', '90', '80']);
  });

  it('keeps a one-id mix body refresh and does not repeat a confirmed page', async () => {
    jest.useFakeTimers();
    const column = ImmutableMap({
      mixId: 'm1',
      sessionId: 1,
      definitionFingerprint: 'fp',
      sources: ImmutableMap({
        [homeKey]: ImmutableMap({ ids: ImmutableList(['100']) }),
      }),
    });
    const state = ImmutableMap({
      externalFeeds: ImmutableMap({ permitted: true }),
      timelines: ImmutableMap(),
      statuses: ImmutableMap({
        100: ImmutableMap({ visibility: 'external' }),
      }),
      settings: ImmutableMap({
        home: ImmutableMap({ shows: ImmutableMap() }),
        mixes: ImmutableList([fromJS({
          id: 'm1',
          version: 1,
          title: 'Desk',
          sources: [homeSource],
        })]),
      }),
      mix_timelines: ImmutableMap({ col: column }),
      meta: ImmutableMap({ me: '1' }),
    });
    const { dispatch } = harness(state);

    externalFeedSession.open('mix:col', { targets: [{ type: 'home' }] });
    dispatch(receiveExternalFeedChanged({
      version: 1,
      reason: 'routes_updated',
      targets: [{ type: 'home' }],
      feed_routes_revision: '4',
      subscription_id: '9',
    }));
    await drain();

    expect(get.mock.calls.some(call => call[0] === '/api/v1/statuses' && call[1].params.id.indexOf('100') !== -1)).toBe(true);
    expect(get.mock.calls.some(call => String(call[0]).indexOf('/api/v1/timelines/home') === 0)).toBe(true);
    const settled = get.mock.calls.length;

    jest.advanceTimersByTime(2000);
    await drain();
    expect(get.mock.calls.length).toBe(settled);
  });
});
