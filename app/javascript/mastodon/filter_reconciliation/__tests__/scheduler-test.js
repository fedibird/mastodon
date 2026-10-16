import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
jest.mock('intl-messageformat', () => function IntlMessageFormat() {
  return { format: () => 'title' };
});
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));
jest.mock('../../stream', () => ({ connectStream: jest.fn((channel, params, factory) => factory) }));

jest.mock('../../api', () => ({ __esModule: true, default: jest.fn(), getLinks: jest.fn() }));
jest.mock('../../initial_state', () => ({ me: 'me', maxFrequentlyUsedEmojis: 16 }));
jest.mock('mastodon/features/emoji/emoji', () => ({
  __esModule: true, default: text => text || '', buildCustomEmojis: () => [], categoriesFromEmojis: () => [],
}));

import api from '../../api';
import rootReducer from '../../reducers';
import { importFetchedStatus, importStatuses } from '../../actions/importer';
import { FILTERS_FETCH_SUCCESS } from '../../actions/filters';
import { makeGetStatus } from '../../selectors';
import { getFilterScheduler, filterReconciliationMiddleware, registerFilterSurface, releaseFilterSurface, prioritizeFilterSurface, candidatesFor, SURFACE_LIMIT } from '../scheduler';
import { normalizeStatusIds } from '../surface';
import { performance as realPerformance } from 'perf_hooks';

const definition = (keyword = 'hello', extra = {}) => ({ id: '1', title: 'hidden', context: ['home'], filter_action: 'hide', expires_at: null, keywords: [{ id: '10', keyword, whole_word: false }], statuses: [], ...extra });
const account = { id: 'other', acct: 'other', username: 'other', display_name: 'Other', note: '', url: 'https://example.com/@other', emojis: [] };
const payload = { id: '101', account, content: '<p>hello</p>', spoiler_text: '', media_attachments: [], emojis: [], mentions: [], tags: [], filtered: [], reblog: null, quote: null, poll: null };
const snapshot = (store, filters) => store.dispatch({ type: FILTERS_FETCH_SUCCESS, filters, receivedAt: Date.now() });
const flush = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};
const tick = async (count = 1) => {
  for (let i = 0; i < count; i++) {
    jest.advanceTimersByTime(80); await flush();
  }
};
const deferred = () => {
  let resolve;
  const promise = new Promise(yes => {
    resolve = yes;
  });
  return { promise, resolve };
};
let post; let get;
const stores = [];
const setup = (count = 1) => {
  const store = createStore(rootReducer, applyMiddleware(thunk, filterReconciliationMiddleware));
  store.dispatch(importFetchedStatus(payload));
  const source = store.getState().getIn(['statuses', '101']).toJS();
  const ids = count === 1 ? ['101'] : Array.from({ length: count }, (_, i) => String(i + 1));
  store.dispatch(importStatuses(ids.map(id => ({ ...source, id }))));
  snapshot(store, [definition()]);
  stores.push(store);
  return { store, ids, scheduler: getFilterScheduler(store.dispatch, store.getState) };
};
beforeEach(() => {
  jest.useFakeTimers('modern');
  jest.setSystemTime(new Date('2026-10-16T12:00:00Z'));
  Object.defineProperty(document, 'hidden', { configurable: true, value: false });
  post = jest.fn((url, { status_ids }) => Promise.resolve({ data: { matches: Object.fromEntries(status_ids.map(id => [id, []])), unavailable: [] } }));
  get = jest.fn().mockResolvedValue({ data: [definition()] });
  api.mockReset().mockReturnValue({ post, get });
});
afterEach(() => {
  stores.forEach(store => {
    const scheduler = getFilterScheduler(store.dispatch, store.getState);
    Array.from(scheduler.surfaces.keys()).forEach(token => scheduler.release(token));
  });
  stores.length = 0;
  jest.clearAllTimers(); jest.useRealTimers();
});

it('normalizes only safe canonical status IDs and preserves bigint wrapper strings', () => {
  expect(normalizeStatusIds([[null, '0', '01', 23, 9007199254740992, '9007199254740993', '-1', '2\n', '23']])).toEqual(['23', '9007199254740993']);
});

it('fetches a missing baseline once; gen 0 and display-only changes do not POST', async () => {
  const { store } = setup();
  store.dispatch(registerFilterSurface('home', { ids: ['101'] }));
  await tick(3);
  snapshot(store, [definition('hello', { title: 'renamed', filter_action: 'warn' })]);
  await tick(3);
  expect(post).not.toHaveBeenCalled();
  const fresh = createStore(rootReducer, applyMiddleware(thunk, filterReconciliationMiddleware)); stores.push(fresh);
  fresh.dispatch(importFetchedStatus(payload));
  fresh.dispatch(registerFilterSurface('fresh', { ids: ['101'] }));
  await tick(3);
  expect(get).toHaveBeenCalledTimes(1);
  expect(post).not.toHaveBeenCalled();
});

it('prioritizes visible, near and retained hidden IDs fairly across columns, chunks 100, and deduplicates', async () => {
  const { store, ids, scheduler } = setup(1000);
  store.dispatch(registerFilterSurface('home', { ids, visible: new Set(['800', '9007199254740993']), near: new Set(['700']) }));
  store.dispatch(registerFilterSurface('history', { ids: ids.slice().reverse(), visible: new Set(['900', '800']), near: new Set(['600']) }));
  snapshot(store, [definition('changed')]);
  await tick(13);
  const calls = post.mock.calls.map(([, body]) => body.status_ids);
  expect(calls).toHaveLength(10);
  expect(calls[0].slice(0, 4)).toEqual(['800', '900', '700', '600']);
  expect(calls.every(batch => batch.length <= 100)).toBe(true);
  const sent = calls.flat();
  expect(new Set(sent).size).toBe(1000);
  expect(sent).toHaveLength(1000);
  expect(post.mock.calls[0][2]).toEqual({ timeout: 15000 });
  expect(scheduler.stats()).toMatchObject({ surfaces: 2, retained: 1001, active: 0, inflight: 0 });
  await tick(100);
  expect(post).toHaveBeenCalledTimes(10);
});

it('bounds retention at 2000 without cycling lower priority rows through the overlay', async () => {
  const { store, ids, scheduler } = setup(2500);
  store.dispatch(registerFilterSurface('a', { ids, visible: new Set(['2400']) }));
  store.dispatch(registerFilterSurface('b', { ids: ids.slice().reverse(), visible: new Set(['2401']) }));
  snapshot(store, [definition('changed')]);
  await tick(25);
  expect(post).toHaveBeenCalledTimes(20);
  expect(store.getState().getIn(['filterMatches', 'entries']).size).toBe(2000);
  expect(scheduler.stats()).toMatchObject({ retained: 2000, attempts: 2000 });
  expect(store.getState().getIn(['filterMatches', 'entries', '2400', 'phase'])).toBe('ready');
  await tick(200);
  expect(post).toHaveBeenCalledTimes(20);
  store.dispatch(releaseFilterSurface('a')); store.dispatch(releaseFilterSurface('b'));
  expect(scheduler.stats()).toEqual({ surfaces: 0, retained: 0, attempts: 0, inflight: 0, active: 0, timers: 0 });
  expect(store.getState().getIn(['filterMatches', 'entries']).size).toBe(0);
});

it('shares ownership, cancels queued work, and rejects late results after unmount', async () => {
  const { store, scheduler } = setup(); const pending = deferred();
  post.mockReturnValueOnce(pending.promise);
  store.dispatch(registerFilterSurface('a', { ids: ['101'] }));
  store.dispatch(registerFilterSurface('b', { ids: ['101'] }));
  snapshot(store, [definition('changed')]); await tick();
  store.dispatch(releaseFilterSurface('a')); await tick();
  expect(store.getState().getIn(['filterMatches', 'entries', '101', 'phase'])).toBe('pending');
  store.dispatch(releaseFilterSurface('b'));
  pending.resolve({ data: { matches: { '101': [] }, unavailable: [] } }); await flush();
  expect(store.getState().getIn(['filterMatches', 'entries', '101'])).toBeUndefined();
  expect(scheduler.stats()).toMatchObject({ active: 0, inflight: 0, timers: 0 });
});

it('waits for old in-flight generations without parallel POSTs, then converges to the new generation', async () => {
  const { store } = setup(); const old = deferred();
  post.mockReturnValueOnce(old.promise);
  store.dispatch(registerFilterSurface('a', { ids: ['101'] }));
  snapshot(store, [definition('first')]); await tick();
  snapshot(store, [definition('second')]); await tick(3);
  expect(post).toHaveBeenCalledTimes(1);
  old.resolve({ data: { matches: { '101': ['1'] }, unavailable: [] } }); await flush(); await tick(3);
  expect(post).toHaveBeenCalledTimes(2);
  expect(store.getState().getIn(['filterMatches', 'entries', '101', 'resultGeneration'])).toBe(2);
});

it('reconciles material edits during flight and preserves all non-overlay Redux subtrees', async () => {
  const { store } = setup(); const old = deferred();
  post.mockReturnValueOnce(old.promise);
  store.dispatch(registerFilterSurface('a', { ids: ['101'] }));
  snapshot(store, [definition('changed')]); await tick();
  store.dispatch(importFetchedStatus({ ...payload, content: 'edited', filtered: [{ filter: definition('changed') }] }));
  const before = store.getState();
  old.resolve({ data: { matches: { '101': ['1'] }, unavailable: [] } }); await flush(); await tick(3);
  expect(post).toHaveBeenCalledTimes(2);
  before.forEach((value, key) => {
    if (key !== 'filterMatches') expect(store.getState().get(key)).toBe(value);
  });
  expect(makeGetStatus()(store.getState(), { id: '101', contextType: 'home' })).not.toBeNull();
});

it.each([401, 403, 422, 429, 'offline', 'timeout', 'unavailable'])('does not loop on %s and recovers only on a later event', async status => {
  const { store } = setup();
  if (status === 'unavailable') post.mockResolvedValueOnce({ data: { matches: {}, unavailable: ['101'] } });
  else post.mockRejectedValueOnce({ response: { status, headers: { 'retry-after': '120' } } });
  store.dispatch(registerFilterSurface('a', { ids: ['101'] }));
  snapshot(store, [definition('changed')]); await tick(3);
  await tick(2000);
  expect(post).toHaveBeenCalledTimes(1);
  document.dispatchEvent(new Event('visibilitychange')); await tick(3);
  expect(post).toHaveBeenCalledTimes(2);
});

it('pauses hidden/offline work and respects Retry-After even for a new generation', async () => {
  const { store } = setup();
  Object.defineProperty(document, 'hidden', { configurable: true, value: true });
  store.dispatch(registerFilterSurface('a', { ids: ['101'] }));
  snapshot(store, [definition('changed')]); await tick(10);
  expect(post).not.toHaveBeenCalled();
  Object.defineProperty(document, 'hidden', { configurable: true, value: false });
  post.mockRejectedValueOnce({ response: { status: 429, headers: { 'retry-after': '120' } } });
  document.dispatchEvent(new Event('visibilitychange')); await tick(3);
  snapshot(store, [definition('again')]); await tick(100);
  expect(post).toHaveBeenCalledTimes(1);
  jest.advanceTimersByTime(120000);
  document.dispatchEvent(new Event('visibilitychange')); await tick(3);
  expect(post).toHaveBeenCalledTimes(2);
});

it('visible revisits retry failed entries only once per event after the cooldown', async () => {
  const { store } = setup();
  post.mockRejectedValueOnce(new Error('offline'));
  store.dispatch(registerFilterSurface('a', { ids: ['101'] }));
  snapshot(store, [definition('changed')]); await tick(3);
  store.dispatch(prioritizeFilterSurface('a', new Set(['101']), new Set(['101']))); await tick(3);
  expect(post).toHaveBeenCalledTimes(1);
  jest.advanceTimersByTime(60000);
  store.dispatch(prioritizeFilterSurface('a', new Set(), new Set()));
  store.dispatch(prioritizeFilterSurface('a', new Set(['101']), new Set(['101']))); await tick(3);
  expect(post).toHaveBeenCalledTimes(2);
});

it('caps registrations and selects visible bigint wrappers before retained IDs', () => {
  const { store, scheduler } = setup();
  for (let i = 0; i < 100; i++) store.dispatch(registerFilterSurface(i, { ids: ['101'] }));
  expect(scheduler.stats().surfaces).toBe(SURFACE_LIMIT);
  expect(Array.from(candidatesFor(new Map([['a', { ids: ['1'], visible: ['9007199254740993'] }], ['b', { ids: ['2'], visible: ['3'] }]])))).toEqual(['9007199254740993', '3', '1', '2']);
});

it('keeps wrapper and original IDs separate, evaluates newly mounted IDs once, and leaves counters alone', async () => {
  const { store } = setup();
  store.dispatch(importFetchedStatus({ ...payload, id: '9007199254740993', reblog: payload }));
  store.dispatch(registerFilterSurface('a', { ids: ['101', '9007199254740993'] }));
  snapshot(store, [definition('changed')]); await tick(4);
  expect(post.mock.calls[0][1].status_ids).toEqual(['101', '9007199254740993']);
  const generation = store.getState().getIn(['filterMatches', 'generation']);
  store.dispatch(importFetchedStatus({ ...payload, favourites_count: 9 })); await tick(4);
  expect(post).toHaveBeenCalledTimes(1);
  store.dispatch(importFetchedStatus({ ...payload, id: '102' }));
  store.dispatch(registerFilterSurface('b', { ids: ['101', '102'] })); await tick(4);
  expect(post.mock.calls[1][1].status_ids).toEqual(['102']);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(generation);
});

it('records bounded scheduler CPU and request counts for 1000/2000 retained IDs', async () => {
  const measurements = [];
  for (const count of [1000, 2000]) {
    const { store, ids, scheduler } = setup(count);
    post.mockClear();
    store.dispatch(registerFilterSurface('a', { ids, visible: new Set(ids.slice(400, 410)) }));
    const started = realPerformance.now();
    snapshot(store, [definition('changed')]); await tick(count / 100 + 3);
    const milliseconds = realPerformance.now() - started;
    measurements.push({ count, posts: post.mock.calls.length, milliseconds, ...scheduler.stats() });
    expect(post).toHaveBeenCalledTimes(count / 100);
    expect(scheduler.stats().attempts).toBe(count);
    store.dispatch(releaseFilterSurface('a'));
    expect(scheduler.stats().retained).toBe(0);
  }
  if (process.env.FILTER_SCHEDULER_PROFILE === '1') {
    // eslint-disable-next-line no-console
    console.info('Filter scheduler profile (real CPU, fake clock)', JSON.stringify(measurements));
  }
});
