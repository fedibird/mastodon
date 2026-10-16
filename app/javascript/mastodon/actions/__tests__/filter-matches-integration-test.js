import { fromJS, is } from 'immutable';
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
import { makeGetStatus } from '../../selectors';
import { filterContextForSource } from '../../mix/filter_context';
import { FILTERS_FETCH_SUCCESS, fetchFilters, scheduleFiltersRefresh } from '../filters';
import { importFetchedStatus, importStatus, importPolls, importFilters } from '../importer';
import { connectUserStream, connectTimelineStream } from '../streaming';
import { submitFilterSettings } from '../../features/embedded_rails_settings/requests';
import { TIMELINE_DELETE, TIMELINE_EXPIRE } from '../timelines';
import { reconcileFilterMatches, clearFilterMatches } from '../filter_matches';
import { FILTER_MATCHES_LIMIT } from '../../reducers/filter_matches';

const definition = (overrides = {}) => ({ id: '1', title: 'hidden', context: ['home'], filter_action: 'hide', expires_at: null, keywords: [{ id: '10', keyword: 'hello', whole_word: false }], statuses: [], ...overrides });
const account = { id: 'other', acct: 'other', username: 'other', display_name: 'Other', note: '', url: 'https://example.com/@other', emojis: [] };
const payload = (overrides = {}) => ({ id: '101', account, content: '<p>hello</p>', spoiler_text: '', media_attachments: [], emojis: [], mentions: [], tags: [], filtered: [{ filter: definition() }], reblog: null, quote: null, poll: null, ...overrides });
const deferred = () => {
  let resolve; let reject; const promise = new Promise((yes, no) => {
    resolve = yes; reject = no;
  }); return { promise, resolve, reject };
};
const snapshot = (store, filters = [definition()]) => store.dispatch({ type: FILTERS_FETCH_SUCCESS, filters });
const overlay = (store, id = '101') => store.getState().getIn(['filterMatches', 'entries', id]);
const select = (store, id = '101', contextType = 'home') => makeGetStatus()(store.getState(), { id, contextType });
const setup = () => {
  const store = createStore(rootReducer, applyMiddleware(thunk));
  store.dispatch(importFetchedStatus(payload()));
  snapshot(store);
  return store;
};
const answer = matches => ({ data: { matches, unavailable: [] } });
let post;
beforeEach(() => {
  post = jest.fn().mockResolvedValue(answer({ '101': [] }));
  api.mockReset().mockReturnValue({ post });
});

it('keeps the first complete snapshot as baseline and ignores order/ID type and display-only changes', () => {
  const store = setup();
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(0);
  const second = definition({ id: 2, keywords: [{ id: 20, keyword: 'bye', whole_word: true }], statuses: [{ id: 30, status_id: '9007199254740993' }, { id: 31, status_id: '102' }] });
  snapshot(store, [definition(), second]);
  const generation = store.getState().getIn(['filterMatches', 'generation']);
  expect(generation).toBe(1);
  snapshot(store, [definition({ ...second, id: '2', keywords: [{ id: '20', keyword: 'bye', whole_word: true }], statuses: [...second.statuses].reverse() }), definition({ id: 1, title: 'renamed', filter_action: 'warn', context: ['public'], expires_at: '2030-01-01T00:00:00Z' })]);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(generation);
  expect(store.getState().getIn(['filters', '1', 'title'])).toBe('renamed');
  expect(post).not.toHaveBeenCalled();
});

it.each([
  { keywords: [{ id: '10', keyword: 'different', whole_word: false }] },
  { keywords: [{ id: '10', keyword: 'hello', whole_word: true }] },
  { keywords: [{ id: '11', keyword: 'hello', whole_word: false }] },
  { keywords: [] },
  { statuses: [{ id: '88', status_id: '9007199254740993' }] },
])('advances generation for a matching rule change: %j', change => {
  const store = setup();
  snapshot(store, [definition(change)]);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(1);
  expect(store.getState().getIn(['filterMatches', 'needsReconcile'])).toBe(true);
});

it('detects target changes, removals, creations and composite changes, excluding empty conditions', () => {
  const store = setup();
  const empty = definition({ id: '2', keywords: [] });
  snapshot(store, [definition(), empty]);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(0);
  snapshot(store, [definition(), definition({ ...empty, statuses: [{ status_id: '9007199254740993' }] })]);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(1);
  snapshot(store, [definition(), definition({ ...empty, statuses: [{ status_id: '9007199254740994' }] })]);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(2);
  snapshot(store, [definition({ title: 'changed', keywords: [] })]);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(3);
  snapshot(store, []);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(3);
});

it('adopts only the newest complete GET when responses arrive out of order', async () => {
  const store = setup();
  const old = deferred(); const recent = deferred();
  api.mockReturnValue({ get: jest.fn().mockReturnValueOnce(old.promise).mockReturnValueOnce(recent.promise) });
  const a = store.dispatch(fetchFilters()); const b = store.dispatch(fetchFilters());
  recent.resolve({ data: [definition({ title: 'latest', keywords: [] })] }); await b;
  old.resolve({ data: [definition()] }); await a;
  expect(store.getState().getIn(['filters', '1', 'title'])).toBe('latest');
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(1);
});

it('protects complete definitions and deletions from stale partial status imports', async () => {
  const store = setup();
  snapshot(store, [definition({ title: 'current', filter_action: 'warn' })]);
  store.dispatch(importFetchedStatus(payload()));
  expect(store.getState().getIn(['filters', '1', 'title'])).toBe('current');
  expect(store.getState().getIn(['filters', '1', 'filter_action'])).toBe('warn');
  await store.dispatch(reconcileFilterMatches(['101']));
  snapshot(store, []);
  store.dispatch(importFetchedStatus(payload()));
  expect(store.getState().get('filters').isEmpty()).toBe(true);
  expect(select(store)).not.toBeNull();
  expect(select(store).get('matched_filters')).toBe(false);
});

it('allows partial imports before baseline without treating them as a complete rules snapshot', () => {
  const store = createStore(rootReducer, applyMiddleware(thunk));
  store.dispatch(importFilters([{ id: '1', title: 'partial', filter_action: 1, context: ['home'] }]));
  expect(store.getState().getIn(['filters', '1', 'filter_action'])).toBe('hide');
  expect(store.getState().getIn(['filterMatches', 'baseline'])).toBe(false);
  snapshot(store);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(0);
});

it('sends only explicitly supplied IDs, preserving bigint strings and normalizing duplicates', async () => {
  const store = setup();
  post.mockResolvedValue(answer({ '101': [], '9007199254740993': ['1'] }));
  await store.dispatch(reconcileFilterMatches(['101', '9007199254740993', '101']));
  expect(post).toHaveBeenCalledWith('/api/v1/fedibird/filters/matches', { status_ids: ['101', '9007199254740993'] });
  expect(overlay(store).get('phase')).toBe('ready');
  expect(select(store)).not.toBeNull();
});

it('distinguishes empty, unavailable and failure; invalid responses cannot clear an old hide', async () => {
  const store = setup();
  post.mockResolvedValueOnce({ data: { matches: {}, unavailable: ['101'] } });
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(overlay(store).get('phase')).toBe('unavailable');
  expect(overlay(store).has('filterIds')).toBe(false);
  expect(select(store)).toBeNull();
  post.mockResolvedValueOnce(answer({}));
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(overlay(store).get('phase')).toBe('failed');
  expect(select(store)).toBeNull();
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(overlay(store).get('filterIds').toJS()).toEqual([]);
  expect(select(store)).not.toBeNull();
});

it.each([401, 403, 422, 'network'])('preserves a current confirmed result on %s and permits explicit retry', async error => {
  const store = setup();
  await store.dispatch(reconcileFilterMatches(['101']));
  post.mockRejectedValueOnce(new Error(String(error)));
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(overlay(store).get('phase')).toBe('failed');
  expect(select(store)).not.toBeNull();
  expect(post).toHaveBeenCalledTimes(2);
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(overlay(store).get('phase')).toBe('ready');
});

it.each([null, [], { matches: null, unavailable: [] }, { matches: [], unavailable: [] }, { matches: { '101': [1] }, unavailable: [] }, { matches: { '101': [] }, unavailable: ['101'] }, { matches: {}, unavailable: ['999'] }, { matches: { '101': [], '999': [] }, unavailable: [] }].map(data => [data]))('rejects malformed/partial/foreign match responses: %j', async data => {
  const store = setup(); post.mockResolvedValue({ data });
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(overlay(store).get('phase')).toBe('failed');
  expect(select(store)).toBeNull();
});

it('rejects old-generation responses and treats legacy fallback as provisional', async () => {
  const store = setup(); const pending = deferred(); post.mockReturnValueOnce(pending.promise);
  const request = store.dispatch(reconcileFilterMatches(['101']));
  snapshot(store, [definition({ keywords: [] })]);
  pending.resolve(answer({ '101': [] })); await request;
  expect(overlay(store).has('resultGeneration')).toBe(false);
  expect(select(store)).toBeNull();
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(select(store)).not.toBeNull();
});

it('resolves partial overlaps per ID so late responses cannot overwrite a newer request', async () => {
  const store = setup();
  store.dispatch(importFetchedStatus(payload({ id: '102' })));
  const old = deferred(); const recent = deferred();
  post.mockReturnValueOnce(old.promise).mockReturnValueOnce(recent.promise);
  const a = store.dispatch(reconcileFilterMatches(['101', '102']));
  const b = store.dispatch(reconcileFilterMatches(['102']));
  recent.resolve(answer({ '102': [] })); await b;
  old.resolve(answer({ '101': ['1'], '102': ['1'] })); await a;
  expect(select(store, '101')).toBeNull();
  expect(select(store, '102')).not.toBeNull();
  expect(overlay(store, '102').get('filterIds').toJS()).toEqual([]);
});

it('keeps wrapper results independent of original and quote results, with existing source contexts', async () => {
  const store = setup();
  store.dispatch(importFetchedStatus(payload({ id: '102', reblog: payload(), account: { ...account, id: 'booster' } })));
  store.dispatch(importFetchedStatus(payload({ id: '103', quote: payload(), filtered: [] })));
  post.mockResolvedValue(answer({ '101': [], '102': ['1'], '103': [] }));
  await store.dispatch(reconcileFilterMatches(['101', '102', '103']));
  expect(select(store, '101')).not.toBeNull();
  expect(select(store, '102')).toBeNull();
  expect(select(store, '103')).not.toBeNull();
  expect(select(store, '102', filterContextForSource({ type: 'home' }))).toBeNull();
  expect(select(store, '102', filterContextForSource({ type: 'public' }))).not.toBeNull();
  expect(select(store, '102', 'list:55')).toBeNull();
  expect(select(store, '102', 'notifications')).not.toBeNull();
});

it('uses current title/action/context/expiry and excludes own posts without changing generation', async () => {
  const store = setup();
  post.mockResolvedValue(answer({ '101': ['1'] }));
  await store.dispatch(reconcileFilterMatches(['101']));
  snapshot(store, [definition({ filter_action: 'warn', title: 'renamed' })]);
  expect(select(store).get('matched_filters').toJS()).toEqual(['renamed']);
  snapshot(store, [definition({ expires_at: '2000-01-01T00:00:00Z' })]);
  expect(select(store).get('matched_filters')).toBe(false);
  snapshot(store, [definition({ context: ['public'] })]);
  expect(select(store)).not.toBeNull();
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(0);
  store.dispatch(importFetchedStatus(payload({ account: { ...account, id: 'me' } })));
  post.mockResolvedValue(answer({ '101': ['1'] }));
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(select(store, '101', 'public').get('matched_filters')).toBe(false);
});

it('does not mutate any existing Redux subtree during reconciliation, including drafts and view state', async () => {
  const store = setup();
  let before = store.getState().merge(fromJS({
    compose: { text: 'primary draft', spoiler_text: 'CW', media_attachments: [{ id: 'm1' }], id: 'editing' },
    composers: { portable: { text: 'portable draft', media_attachments: [{ id: 'm2' }] } },
    history: { past: ['101'], future: ['102'], index: 1 },
    timelines: { home: { items: ['101'], pendingItems: ['102'], top: false }, mix: { items: ['101'] } },
  }));
  before = before.setIn(['statuses', '101', 'translation'], fromJS({ content: 'translation' })).setIn(['statuses', '101', 'translationMode'], 'bilingual').setIn(['statuses', '101', 'emoji_reactions'], fromJS([{ name: 'heart', count: 3 }]));
  const protectedStore = createStore(rootReducer, before, applyMiddleware(thunk));
  await protectedStore.dispatch(reconcileFilterMatches(['101']));
  before.forEach((value, key) => {
    if (key !== 'filterMatches') expect(protectedStore.getState().get(key)).toBe(value);
  });
  expect(is(before.get('statuses'), protectedStore.getState().get('statuses'))).toBe(true);
});

it.each(['content', 'spoiler_text', 'edited_at', 'references', 'status_reference_ids', 'media_attachments'])('invalidates an in-flight result on %s changes', async field => {
  const store = setup(); const pending = deferred(); post.mockReturnValueOnce(pending.promise);
  const request = store.dispatch(reconcileFilterMatches(['101']));
  const changed = { content: 'edited', spoiler_text: 'CW', edited_at: '2030-01-01', references: ['https://example.com/new'], status_reference_ids: ['222'], media_attachments: [{ id: '88', description: 'changed ALT', type: 'image' }] };
  store.dispatch(importFetchedStatus(payload({ [field]: changed[field] })));
  pending.resolve(answer({ '101': [] })); await request;
  expect(overlay(store).get('phase')).toBe('unevaluated');
  expect(overlay(store).has('filterIds')).toBe(false);
  await store.dispatch(reconcileFilterMatches(['101']));
  expect(select(store)).not.toBeNull();
});

it('invalidates wrapper matches when its original or poll options change, not when counters/filtered change', async () => {
  const store = setup();
  const poll = { id: '77', options: [{ title: 'choice' }], emojis: [] };
  store.dispatch(importFetchedStatus(payload({ id: '102', reblog: payload({ poll }) })));
  post.mockResolvedValue(answer({ '102': [] }));
  await store.dispatch(reconcileFilterMatches(['102']));
  store.dispatch(importFetchedStatus(payload({ poll, favourites_count: 99, filtered: [{ filter: definition({ title: 'stale' }) }] })));
  expect(overlay(store, '102').get('phase')).toBe('ready');
  expect(select(store, '102')).not.toBeNull();
  store.dispatch(importPolls([{ ...poll, options: [{ title: 'changed' }] }]));
  expect(overlay(store, '102').get('phase')).toBe('unevaluated');
  await store.dispatch(reconcileFilterMatches(['102']));
  store.dispatch(importStatus({ ...store.getState().getIn(['statuses', '101']).toJS(), content: 'new original' }));
  expect(overlay(store, '102').get('phase')).toBe('unevaluated');
});

it('keeps a confirmed result when only stale filtered metadata is reimported', async () => {
  const store = setup();
  await store.dispatch(reconcileFilterMatches(['101']));
  store.dispatch(importFetchedStatus(payload()));
  expect(overlay(store).get('phase')).toBe('ready');
  expect(select(store)).not.toBeNull();
});

it.each([TIMELINE_DELETE, TIMELINE_EXPIRE])('cleans up %s and rejects its outstanding responses', async type => {
  const store = setup(); const pending = deferred(); post.mockReturnValueOnce(pending.promise);
  const request = store.dispatch(reconcileFilterMatches(['101']));
  store.dispatch({ type, id: '101', references: [], quotes: [] });
  pending.resolve(answer({ '101': [] })); await request;
  expect(overlay(store)).toBeUndefined();
});

it('bounds entries, evicts old requests, and provides explicit cleanup without resetting serials', async () => {
  const store = setup();
  for (let i = 0; i < FILTER_MATCHES_LIMIT / 100 + 1; i++) {
    const ids = Array.from({ length: 100 }, (_, j) => String(i * 100 + j + 1));
    post.mockResolvedValue(answer(Object.fromEntries(ids.map(id => [id, []]))));
    await store.dispatch(reconcileFilterMatches(ids));
  }
  expect(store.getState().getIn(['filterMatches', 'entries']).size).toBe(FILTER_MATCHES_LIMIT);
  expect(overlay(store, '1')).toBeUndefined();
  store.dispatch(clearFilterMatches(['2100']));
  expect(overlay(store, '2100')).toBeUndefined();
  const serial = store.getState().getIn(['filterMatches', 'serial']);
  store.dispatch(clearFilterMatches());
  expect(store.getState().getIn(['filterMatches', 'entries']).isEmpty()).toBe(true);
  expect(store.getState().getIn(['filterMatches', 'serial'])).toBe(serial);
});

it.each([[1], ['-1'], ['1.2'], ['01'], ['9223372036854775808'], ['1\n'], [null], Array(101).fill('1')].map(ids => [ids]))('rejects invalid explicit IDs before sending: %j', async ids => {
  const store = setup();
  await expect(store.dispatch(reconcileFilterMatches(ids))).rejects.toThrow(TypeError);
  expect(post).not.toHaveBeenCalled();
});

it('does not request empty input or reconcile before a complete baseline', async () => {
  const store = createStore(rootReducer, applyMiddleware(thunk));
  await store.dispatch(reconcileFilterMatches([]));
  await expect(store.dispatch(reconcileFilterMatches(['101']))).rejects.toThrow('Fetch complete');
  expect(post).not.toHaveBeenCalled();
});

const flush = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve();
};

describe('user stream and embedded saves', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => {
    jest.clearAllTimers(); jest.useRealTimers();
  });

  it('coalesces reconnect and event bursts on user streams, ignoring other channels', async () => {
    const store = setup();
    const get = jest.fn().mockResolvedValue({ data: [definition({ title: 'stream current' })] });
    api.mockReturnValue({ get });
    const user = connectUserStream()(store.dispatch, store.getState);
    const publicStream = connectTimelineStream('public', 'public')(store.dispatch, store.getState);
    publicStream.onConnect(); publicStream.onReceive({ event: 'filters_changed' });
    jest.advanceTimersByTime(1000); await flush();
    expect(get).not.toHaveBeenCalled();
    user.onConnect(); user.onConnect();
    for (let i = 0; i < 100; i++) user.onReceive({ event: 'filters_changed' });
    jest.advanceTimersByTime(249); expect(get).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1); await flush();
    expect(get).toHaveBeenCalledTimes(1);
    expect(store.getState().getIn(['filters', '1', 'title'])).toBe('stream current');
    jest.advanceTimersByTime(60000); await flush();
    expect(get).toHaveBeenCalledTimes(1);
  });

  it('allows one in-flight and one trailing refresh, without retry loops after failure', async () => {
    const store = setup(); const pending = deferred();
    const get = jest.fn().mockReturnValueOnce(pending.promise).mockRejectedValueOnce(new Error('network'));
    api.mockReturnValue({ get });
    store.dispatch(scheduleFiltersRefresh());
    jest.advanceTimersByTime(250); await flush();
    for (let i = 0; i < 100; i++) store.dispatch(scheduleFiltersRefresh());
    jest.advanceTimersByTime(10000); await flush();
    expect(get).toHaveBeenCalledTimes(1);
    pending.resolve({ data: [definition()] }); await flush();
    jest.advanceTimersByTime(250); await flush();
    expect(get).toHaveBeenCalledTimes(2);
    jest.advanceTimersByTime(60000); await flush();
    expect(get).toHaveBeenCalledTimes(2);
  });

  it('does not let a pre-save stream GET overwrite the post-commit iframe GET', async () => {
    const store = setup(); const old = deferred(); const recent = deferred();
    const get = jest.fn().mockReturnValueOnce(old.promise).mockReturnValueOnce(recent.promise);
    api.mockReturnValue({ get });
    store.dispatch(scheduleFiltersRefresh());
    jest.advanceTimersByTime(250); await flush();
    window.fetch = jest.fn().mockResolvedValue({ ok: true });
    const save = submitFilterSettings(new URL('/filters?embedded=1', window.location.origin), new FormData(), store.dispatch);
    await flush();
    recent.resolve({ data: [definition({ title: 'saved', keywords: [] })] }); await save;
    old.resolve({ data: [definition()] }); await flush();
    expect(store.getState().getIn(['filters', '1', 'title'])).toBe('saved');
    expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(1);
    expect(get).toHaveBeenCalledTimes(2);
  });
});

it('ignores keyword/target permutations and target-row identities, but detects target removal', () => {
  const store = setup();
  const first = definition({ keywords: [{ id: 10, keyword: 'hello', whole_word: false }, { id: 11, keyword: 'bye', whole_word: true }], statuses: [{ id: '51', status_id: '102' }, { id: '52', status_id: '9007199254740993' }] });
  snapshot(store, [first]);
  const generation = store.getState().getIn(['filterMatches', 'generation']);
  snapshot(store, [definition({ ...first, keywords: first.keywords.slice().reverse().map(keyword => ({ ...keyword, id: String(keyword.id) })), statuses: [{ id: '99', status_id: '9007199254740993' }, { id: '98', status_id: 102 }] })]);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(generation);
  snapshot(store, [definition({ ...first, statuses: first.statuses.slice(1) })]);
  expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(generation + 1);
});

it('rejects a request predating an edit even when content later returns to its original value', async () => {
  const store = setup(); const pending = deferred(); post.mockReturnValueOnce(pending.promise);
  const request = store.dispatch(reconcileFilterMatches(['101']));
  store.dispatch(importFetchedStatus(payload({ content: '<p>changed</p>' })));
  store.dispatch(importFetchedStatus(payload()));
  pending.resolve(answer({ '101': [] })); await request;
  expect(overlay(store).get('phase')).toBe('unevaluated');
  expect(select(store)).toBeNull();
});

it('cannot restore cleared results or overwrite a newer result with a late failed request', async () => {
  const store = setup(); const old = deferred(); post.mockReturnValueOnce(old.promise);
  const request = store.dispatch(reconcileFilterMatches(['101']));
  store.dispatch(clearFilterMatches(['101']));
  await store.dispatch(reconcileFilterMatches(['101']));
  old.reject(new Error('old request failed')); await request;
  expect(overlay(store).get('phase')).toBe('ready');
  expect(select(store)).not.toBeNull();
});
