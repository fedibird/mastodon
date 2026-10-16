import { fromJS } from 'immutable';
import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({ defineMessages: messages => messages, injectIntl: Component => Component, FormattedMessage: () => null }));
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

import React from 'react';
import { Provider } from 'react-redux';
import { render, act } from '@testing-library/react';
import { Router } from 'react-router-dom';
import { createMemoryHistory } from 'history';

jest.mock('../../containers/scroll_container', () => ({ children }) => children);
jest.mock('../../components/regeneration_indicator', () => () => null);
jest.mock('../../components/load_gap', () => () => null);
jest.mock('../../containers/status_container', () => {
  const React = require('react');
  const { connect } = require('react-redux');
  const { makeGetStatus } = require('../../selectors');
  return connect(() => {
    const select = makeGetStatus();
    return (state, props) => ({ status: select(state, props) });
  })(({ status }) => status ? <div data-status={status.get('id')}>{status.get('content')}</div> : null);
});

import api from '../../api';
import rootReducer from '../../reducers';
import StatusList from '../../components/status_list';
import { importFetchedStatus } from '../../actions/importer';
import { FILTERS_FETCH_SUCCESS } from '../../actions/filters';
import { filterReconciliationMiddleware, getFilterScheduler, registerFilterSurface } from '../scheduler';
import { notificationStatusIds, notificationStatusForRow } from '../notifications';
import { mixTimelineView } from '../../mix/view';

const definition = (extra = {}) => ({ id: '1', title: 'hidden', context: ['home'], filter_action: 'hide', expires_at: null, keywords: [{ id: '10', keyword: 'hello', whole_word: false }], statuses: [], ...extra });
const account = { id: 'other', acct: 'other', username: 'other', display_name: 'Other', note: '', url: 'https://example.com/@other', emojis: [] };
const payload = id => ({ id, account, content: '<p>hello</p>', spoiler_text: '', media_attachments: [], emojis: [], mentions: [], tags: [], filtered: [{ filter: definition() }], reblog: null, quote: null, poll: null });
const snapshot = (store, extra) => store.dispatch({ type: FILTERS_FETCH_SUCCESS, filters: [definition(extra)], receivedAt: Date.now() });
const tick = async (count = 1) => {
  await act(async () => {
    for (let i = 0; i < count; i++) {
      jest.advanceTimersByTime(80);
      for (let j = 0; j < 20; j++) await Promise.resolve();
    }
  });
};
let store; let post;
beforeEach(() => {
  jest.useFakeTimers('modern');
  Object.defineProperty(document, 'hidden', { configurable: true, value: false });
  global.IntersectionObserver = class {

    observe() {}
    unobserve() {}
    disconnect() {}

  };
  store = createStore(rootReducer, applyMiddleware(thunk, filterReconciliationMiddleware));
  ['101', '102', '9007199254740993'].forEach(id => store.dispatch(importFetchedStatus(payload(id))));
  snapshot(store);
  post = jest.fn((url, { status_ids }) => Promise.resolve({ data: { matches: Object.fromEntries(status_ids.map(id => [id, []])), unavailable: [] } }));
  api.mockReset().mockReturnValue({ post });
});
afterEach(() => {
  const scheduler = getFilterScheduler(store.dispatch, store.getState);
  Array.from(scheduler.surfaces.keys()).forEach(token => scheduler.release(token));
  jest.clearAllTimers(); jest.useRealTimers();
});

it('registers two actual mounted StatusLists with the same scroll key independently and restores hidden rows without removing IDs', async () => {
  const ids = fromJS(['101', null, '102']);
  const props = { scrollKey: 'same', trackScroll: false, timelineId: 'home', statusIds: ids, featuredStatusIds: fromJS(['9007199254740993']), trackIntersection: false };
  const view = render(<Provider store={store}><><StatusList {...props} /><StatusList {...props} /></></Provider>);
  const scheduler = getFilterScheduler(store.dispatch, store.getState);
  expect(scheduler.stats().surfaces).toBe(2);
  expect(view.container.querySelectorAll('[data-status]').length).toBe(0);
  act(() => snapshot(store, { keywords: [] }));
  await tick(5);
  expect(post).toHaveBeenCalledTimes(1);
  expect(new Set(post.mock.calls[0][1].status_ids)).toEqual(new Set(['101', '102', '9007199254740993']));
  expect(view.container.querySelectorAll('[data-status]').length).toBe(6);
  expect(ids.toJS()).toEqual(['101', null, '102']);
  view.rerender(<Provider store={store}><StatusList {...props} scrollKey='new-route' /></Provider>);
  await tick(3);
  expect(scheduler.stats().surfaces).toBe(1);
  view.unmount();
  expect(scheduler.stats()).toMatchObject({ surfaces: 0, retained: 0, attempts: 0, timers: 0 });
});

it('extracts notification.status, not notification IDs; follow/report and gaps are excluded', async () => {
  const notifications = fromJS([{ id: '9001', type: 'mention', status: '101' }, null, { id: '9002', type: 'status', status: '9007199254740993' }, { id: '9003', type: 'follow', status: '102' }, { id: '9004', type: 'admin.report', status: '102' }]);
  const ids = notificationStatusIds(notifications);
  expect(ids).toEqual(['101', '9007199254740993']);
  expect(notificationStatusForRow(notifications, '9001')).toBe('101');
  expect(notificationStatusForRow(notifications, '9003')).toBeUndefined();
  store.dispatch(registerFilterSurface('notifications', { ids }));
  snapshot(store, { keywords: [] });
  const before = store.getState().get('notifications');
  await tick(4);
  expect(post.mock.calls[0][1].status_ids).toEqual(ids);
  expect(store.getState().get('notifications')).toBe(before);
});

const source = (type, ids) => ({ descriptor: { type, params: {} }, ids, loaded: true, hasMore: false, filterResults: Object.fromEntries(ids.map(id => [id, [{ filter: '1' }]])) });
const timeline = () => fromJS({ sources: { home: source('home', ['102', '101']), public: source('public', ['101']) }, live: { home: { ids: ['9007199254740993'], filterResults: { '9007199254740993': [{ filter: '1' }] } } }, pendingStatusIds: [], deletedStatusIds: [], displayMode: 'history', split: { history: { sources: { home: source('home', ['102', '101']) }, frozenLive: {} } } });
const mix = (pane, record = timeline()) => mixTimelineView(record, store.getState().get('statuses'), store.getState().get('filters'), 'me', pane, store.getState().get('filterMatches'));

it('collects prefiltered Mix source/live/history IDs and recomputes resurrection with context-sensitive overlay', async () => {
  const before = mix('history');
  expect(before.statusIds.toJS()).toEqual([]);
  expect(before.reconciliationIds.toJS()).toEqual(['102', '101']);
  const single = mix(undefined, timeline().delete('split'));
  expect(single.statusIds.toJS()).toEqual(['101']);
  expect(single.contextById['101']).toBe('public');
  expect(single.reconciliationIds.toJS()).toEqual(['102', '101', '9007199254740993']);
  store.dispatch(registerFilterSurface('mix-history', { ids: before.reconciliationIds }));
  store.dispatch(registerFilterSurface('mix-live', { ids: single.reconciliationIds }));
  snapshot(store, { keywords: [] });
  await tick(4);
  expect(mix('history').statusIds.toJS()).toEqual(['102', '101']);
  expect(mix(undefined, timeline().delete('split')).statusIds.toJS()).toEqual(['9007199254740993', '102', '101']);
  expect(post).toHaveBeenCalledTimes(1);
  expect(timeline().getIn(['split', 'history', 'sources', 'home', 'ids']).toJS()).toEqual(['102', '101']);
});

it('lets a Mix hide apply only to home while public membership stays visible', async () => {
  post.mockImplementation((url, { status_ids }) => Promise.resolve({ data: { matches: Object.fromEntries(status_ids.map(id => [id, ['1']])), unavailable: [] } }));
  const record = timeline().delete('split');
  store.dispatch(registerFilterSurface('mix', { ids: mix(undefined, record).reconciliationIds }));
  snapshot(store, { keywords: [{ id: '10', keyword: 'changed', whole_word: false }] }); await tick(4);
  const view = mix(undefined, record);
  expect(view.statusIds.toJS()).toEqual(['101']);
  expect(view.contextById['101']).toBe('public');
  expect(view.sourceKeysById['101']).toEqual(['public']);
});

it.each(['search results', 'detailed status'])('leaves the existing contextless %s selector contract outside automatic registration', async () => {
  const { makeGetStatus } = require('../../selectors');
  const select = makeGetStatus();
  const statuses = store.getState().get('statuses');
  expect(select(store.getState(), { id: '101' })).not.toBeNull();
  act(() => snapshot(store, { keywords: [{ id: '10', keyword: 'changed', whole_word: false }] }));
  await tick(3);
  expect(getFilterScheduler(store.dispatch, store.getState).stats().surfaces).toBe(0);
  expect(post).not.toHaveBeenCalled();
  expect(select(store.getState(), { id: '101' })).not.toBeNull();
  expect(store.getState().get('statuses')).toBe(statuses);
});

it('scopes a reused list to its router session key while keeping modal navigation stable', () => {
  const history = createMemoryHistory();
  const view = render(<Router history={history}><Provider store={store}><StatusList scrollKey='reused-account' trackScroll={false} timelineId='account' statusIds={fromJS(['101'])} /></Provider></Router>);
  const scheduler = getFilterScheduler(store.dispatch, store.getState);
  const first = Array.from(scheduler.surfaces.keys())[0];
  act(() => history.push('/next-account'));
  const second = Array.from(scheduler.surfaces.keys())[0];
  expect(second).not.toBe(first);
  expect(first.frame).toBeNull();
  act(() => history.push('/next-account', { mastodonModalKey: 'media' }));
  expect(Array.from(scheduler.surfaces.keys())[0]).toBe(second);
  view.unmount();
  expect(scheduler.stats().surfaces).toBe(0);
});
