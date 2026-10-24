import { fromJS, Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));
jest.mock('../../stream', () => ({ connectStream: (channel, params, factory) => factory }));
jest.mock('../../api', () => ({ __esModule: true, default: jest.fn(), getLinks: () => ({ refs: [] }) }));
jest.mock('../filter_definitions', () => ({
  ...jest.requireActual('../filter_definitions'),
  revalidateUnknownFilters: () => ({ type: 'NOOP_REVALIDATE' }),
}));

import api from '../../api';
import externalBoosts from '../../reducers/external_boosts';
import timelines from '../../reducers/timelines';
import mixTimelines from '../../reducers/mix_timelines';
import statuses from '../../reducers/statuses';
import { FLOOR_LIMIT } from '../../external_boosts/revision';
import {
  EXTERNAL_LINK_BOOST_CHANGED,
  HELD_BOOST_BATCH,
  receiveExternalLinkBoostChanged,
  reconcileHeldExternalBoosts,
  resetExternalBoostReconcileForTests,
} from '../external_boosts';
import { importFetchedStatus, importFetchedStatuses } from '../importer';
import { updateStatus } from '../statuses';
import { connectTimelineStream } from '../streaming';

const projection = (id, revision, reblogged, extra = {}) => ({
  id,
  content: `body ${id}`,
  reblogged,
  account: { id: '1', acct: 'me', username: 'me', display_name: 'me', note: '', url: 'https://example.com/@me', emojis: [], fields: [] },
  media_attachments: [],
  emojis: [],
  mentions: [],
  tags: [],
  fedibird_external: { protocol: 'rss', link_boost_revision: revision },
  ...extra,
});

const buildStore = (initial = {}) => {
  const reducer = combineReducers({
    statuses,
    externalBoosts,
    accounts: (state = ImmutableMap()) => state,
    polls: (state = ImmutableMap()) => state,
    meta: (state = ImmutableMap({ locale: 'en' })) => state,
  });
  const base = reducer(undefined, { type: '@@INIT' });
  const seeded = Object.keys(initial).reduce((state, key) => state.setIn(['statuses', key], fromJS(initial[key])), base);

  return createStore(reducer, seeded, applyMiddleware(thunk));
};

const pair = (store, id = '100') => [store.getState().getIn(['statuses', id, 'reblogged']), store.getState().getIn(['statuses', id, 'fedibird_external', 'link_boost_revision'])];

beforeEach(() => {
  resetExternalBoostReconcileForTests();
  api.mockReset();
});

describe('receiveExternalLinkBoostChanged', () => {
  it('dispatches only a well-formed event and ignores everything else', () => {
    const store = buildStore();
    const seen = [];
    const dispatch = action => {
      seen.push(action);
      return store.dispatch(action);
    };
    const run = payload => receiveExternalLinkBoostChanged(payload)(dispatch);

    run('not json');
    run(JSON.stringify({ version: 1, status_id: '5', reblogged: 'yes', revision: '1' }));
    run(JSON.stringify({ version: 2, status_id: '5', reblogged: true, revision: '1' }));
    run(JSON.stringify({ version: 1, status_id: 5, reblogged: true, revision: '1' }));
    run(JSON.stringify({ version: 1, status_id: '5', reblogged: true, revision: 1 }));
    run(JSON.stringify({ version: 1, status_id: '05', reblogged: true, revision: '1' }));
    run(JSON.stringify({ version: 1, status_id: '5', reblogged: true, revision: '01' }));
    run(null);
    run([]);
    expect(seen).toEqual([]);

    run(JSON.stringify({ version: 1, status_id: '9007199254740993', reblogged: true, revision: '9007199254740995', extra: 'x' }));
    expect(seen).toEqual([{ type: EXTERNAL_LINK_BOOST_CHANGED, statusId: '9007199254740993', reblogged: true, revision: '9007199254740995' }]);
  });
});

describe('external boost floor for statuses that are not held', () => {
  it('keeps an import that was already in flight from landing with an older pair', () => {
    const store = buildStore();

    store.dispatch(receiveExternalLinkBoostChanged(JSON.stringify({ version: 1, status_id: '100', reblogged: false, revision: '4' })));
    expect(store.getState().get('statuses').size).toBe(0);

    store.dispatch(importFetchedStatuses([projection('100', '3', true)]));
    expect(pair(store)).toEqual([false, '4']);
    expect(store.getState().getIn(['statuses', '100', 'content'])).toBe('body 100');

    store.dispatch(importFetchedStatuses([projection('100', '5', true)]));
    expect(pair(store)).toEqual([true, '5']);
  });

  it('does not touch an ordinary status or a payload that has no revision', () => {
    const store = buildStore();

    store.dispatch(receiveExternalLinkBoostChanged(JSON.stringify({ version: 1, status_id: '100', reblogged: false, revision: '4' })));
    store.dispatch(importFetchedStatus(projection('200', '1', true, { fedibird_external: undefined })));
    store.dispatch(importFetchedStatus({ ...projection('100', '1', true), fedibird_external: undefined }));

    expect(store.getState().getIn(['statuses', '200', 'reblogged'])).toBe(true);
    expect(store.getState().getIn(['statuses', '100', 'reblogged'])).toBe(true);
  });

  it('is bounded and keeps the newest entries', () => {
    const store = buildStore();

    for (let index = 1; index <= FLOOR_LIMIT + 20; index += 1) {
      store.dispatch(receiveExternalLinkBoostChanged(JSON.stringify({ version: 1, status_id: String(index), reblogged: true, revision: '1' })));
    }

    const floor = store.getState().get('externalBoosts');

    expect(floor.size).toBe(FLOOR_LIMIT);
    expect(floor.has('1')).toBe(false);
    expect(floor.has(String(FLOOR_LIMIT + 20))).toBe(true);
  });

  it('never lowers a floor', () => {
    const store = buildStore();

    store.dispatch(receiveExternalLinkBoostChanged(JSON.stringify({ version: 1, status_id: '100', reblogged: false, revision: '9' })));
    store.dispatch(receiveExternalLinkBoostChanged(JSON.stringify({ version: 1, status_id: '100', reblogged: true, revision: '8' })));

    expect(store.getState().getIn(['externalBoosts', '100', 'revision'])).toBe('9');
    expect(store.getState().getIn(['externalBoosts', '100', 'reblogged'])).toBe(false);
  });
});

describe('streaming wiring', () => {
  const wire = (store) => {
    const dispatch = action => (typeof action === 'function' ? action(dispatch, store.getState) : store.dispatch(action));

    return connectTimelineStream('home', 'user', {})(dispatch, store.getState);
  };

  it('applies the event to a held status and leaves other statuses alone', () => {
    const store = buildStore({ 100: projection('100', '1', true), 101: { id: '101', reblogged: true } });
    const handler = wire(store);

    handler.onReceive({ event: 'external_link_boost_changed', payload: JSON.stringify({ version: 1, status_id: '100', reblogged: false, revision: '2' }) });
    handler.onReceive({ event: 'external_link_boost_changed', payload: JSON.stringify({ version: 1, status_id: '100', reblogged: true, revision: '1' }) });

    expect(pair(store)).toEqual([false, '2']);
    expect(store.getState().getIn(['statuses', '101', 'reblogged'])).toBe(true);
  });

  it('does not accumulate statuses for events of statuses that are not held', () => {
    const store = buildStore();
    const handler = wire(store);

    for (let index = 1; index <= 50; index += 1) {
      handler.onReceive({ event: 'external_link_boost_changed', payload: JSON.stringify({ version: 1, status_id: String(index), reblogged: true, revision: '1' }) });
    }

    expect(store.getState().get('statuses').size).toBe(0);
  });
});

describe('reconcileHeldExternalBoosts', () => {
  const clientReturning = (data) => {
    const get = jest.fn(() => Promise.resolve({ data }));

    api.mockImplementation(() => ({ get }));

    return get;
  };

  it('does nothing when no held status carries a revision', async () => {
    const get = clientReturning([]);
    const store = buildStore({ 1: { id: '1', reblogged: true } });

    await store.dispatch(reconcileHeldExternalBoosts({ force: true }));
    expect(get).not.toHaveBeenCalled();
  });

  it('reads held projections once, newest first and bounded, and repairs a missed event', async () => {
    const initial = {};

    for (let index = 1; index <= HELD_BOOST_BATCH + 10; index += 1) {
      initial[String(index)] = projection(String(index), '1', true);
    }

    initial['5000'] = { id: '5000', reblogged: true };

    const store = buildStore(initial);
    const get = clientReturning([projection(String(HELD_BOOST_BATCH + 10), '2', false)]);

    await store.dispatch(reconcileHeldExternalBoosts({ force: true }));

    expect(get).toHaveBeenCalledTimes(1);
    const ids = get.mock.calls[0][1].params.id;

    expect(ids).toHaveLength(HELD_BOOST_BATCH);
    expect(ids[0]).toBe(String(HELD_BOOST_BATCH + 10));
    expect(ids).not.toContain('5000');
    expect(pair(store, String(HELD_BOOST_BATCH + 10))).toEqual([false, '2']);
  });

  it('cannot roll back a state that arrived while the request was in flight', async () => {
    const store = buildStore({ 100: projection('100', '1', true) });
    let resolve;
    const get = jest.fn(() => new Promise(done => {
      resolve = done;
    }));

    api.mockImplementation(() => ({ get }));
    const pending = store.dispatch(reconcileHeldExternalBoosts({ force: true }));

    store.dispatch(receiveExternalLinkBoostChanged(JSON.stringify({ version: 1, status_id: '100', reblogged: false, revision: '3' })));
    resolve({ data: [projection('100', '2', true)] });
    await pending;

    expect(pair(store)).toEqual([false, '3']);
  });

  it('keeps a minimum gap between runs unless forced, and swallows a failure', async () => {
    const get = jest.fn(() => Promise.reject(new Error('offline')));

    api.mockImplementation(() => ({ get }));
    const store = buildStore({ 100: projection('100', '1', true) });

    await store.dispatch(reconcileHeldExternalBoosts());
    await store.dispatch(reconcileHeldExternalBoosts());
    expect(get).toHaveBeenCalledTimes(1);
    await store.dispatch(reconcileHeldExternalBoosts({ force: true }));
    expect(get).toHaveBeenCalledTimes(2);
    expect(pair(store)).toEqual([true, '1']);
  });

  it('is run by a reconnect of the user stream and not by the first connect', () => {
    const get = clientReturning([]);
    const store = buildStore({ 100: projection('100', '1', true) });
    const full = ImmutableMap({ timelines: ImmutableMap(), externalFeeds: ImmutableMap({ permitted: false }), settings: fromJS({ home: { shows: {} } }) });
    const getState = () => store.getState().merge(full);
    const dispatch = action => (typeof action === 'function' ? action(dispatch, getState) : store.dispatch(action));
    const handler = connectTimelineStream('home', 'user', {})(dispatch, getState);

    handler.onConnect();
    expect(get.mock.calls.filter(call => call[0] === '/api/v1/statuses')).toHaveLength(0);
    handler.onDisconnect();
    handler.onConnect();
    expect(get.mock.calls.filter(call => call[0] === '/api/v1/statuses')).toHaveLength(1);
  });
});

describe('timelines are not touched by a share state change', () => {
  const buildWithTimelines = () => {
    const reducer = combineReducers({
      statuses,
      externalBoosts,
      timelines,
      mix_timelines: mixTimelines,
      accounts: (state = ImmutableMap()) => state,
      polls: (state = ImmutableMap()) => state,
      meta: (state = ImmutableMap({ locale: 'en' })) => state,
    });
    let state = reducer(undefined, { type: '@@INIT' });

    state = state.setIn(['statuses', '100'], fromJS(projection('100', '1', true)));
    state = state.setIn(['timelines', 'home'], fromJS({ items: ['300', '100', '50'], pendingItems: ['400'], unread: 1, top: false, isLoading: false, hasMore: true, isPartial: false }));
    state = state.setIn(['timelines', 'list:7'], fromJS({ items: ['100'], pendingItems: [], unread: 0, top: true, isLoading: false, hasMore: false, isPartial: false }));

    return { store: createStore(reducer, state, applyMiddleware(thunk)), reducer };
  };

  it('updates the flag of the same id in place and leaves every list, pending item, and counter as it was', () => {
    const { store } = buildWithTimelines();
    const before = store.getState();

    store.dispatch(receiveExternalLinkBoostChanged(JSON.stringify({ version: 1, status_id: '100', reblogged: false, revision: '2' })));
    const after = store.getState();

    expect(after.get('timelines')).toBe(before.get('timelines'));
    expect(after.get('mix_timelines')).toBe(before.get('mix_timelines'));
    expect(after.getIn(['timelines', 'home', 'items']).toJS()).toEqual(['300', '100', '50']);
    expect(after.getIn(['statuses', '100', 'reblogged'])).toBe(false);
    expect(after.get('statuses').size).toBe(1);
  });

  it('keeps timelines as they were when a stale status.update arrives after a newer event', () => {
    const { store } = buildWithTimelines();

    store.dispatch(receiveExternalLinkBoostChanged(JSON.stringify({ version: 1, status_id: '100', reblogged: false, revision: '2' })));
    const before = store.getState().get('timelines');

    store.dispatch(updateStatus(projection('100', '1', true, { content: 'edit' })));

    expect(store.getState().get('timelines')).toBe(before);
    expect(pair(store)).toEqual([false, '2']);
    expect(store.getState().getIn(['statuses', '100', 'content'])).toBe('edit');
  });
});
