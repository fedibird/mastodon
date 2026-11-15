import React from 'react';
import { act } from 'react-dom/test-utils';
import { Provider, connect } from 'react-redux';
import { createStore, applyMiddleware } from 'redux';
import { render, screen } from '@testing-library/react';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
jest.mock('intl-messageformat', () => function IntlMessageFormat() {
  return { format: () => 'title' };
});
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));
jest.mock('../../stream', () => ({ connectStream: jest.fn() }));
jest.mock('../../api', () => ({ __esModule: true, default: jest.fn(), getLinks: jest.fn() }));
jest.mock('../../initial_state', () => ({ me: 'me', maxFrequentlyUsedEmojis: 16 }));
jest.mock('mastodon/features/emoji/emoji', () => ({
  __esModule: true, default: text => text || '', buildCustomEmojis: () => [], categoriesFromEmojis: () => [],
}));

import rootReducer from '../../reducers';
import { makeGetStatus } from '../../selectors';
import { importFetchedStatus } from '../importer';
import { FILTERS_FETCH_SUCCESS } from '../filters';
import { TIMELINE_UPDATE } from '../timelines';
import { armFilterExpiry, FILTERS_EXPIRY_TICK } from '../filter_expiry';

const account = { id: 'other', acct: 'other', username: 'other', display_name: 'Other', note: '', url: 'https://example.com/@other', emojis: [] };
const status = {
  id: '101',
  account,
  content: '<p>live post</p>',
  spoiler_text: '',
  media_attachments: [],
  emojis: [],
  mentions: [],
  tags: [],
  filtered: [{ filter: '1' }],
  reblog: null,
  quote: null,
  poll: null,
};

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();

  return (state, props) => ({
    status: getStatus(state, props),
  });
};

const Row = connect(makeMapStateToProps)(({ status: visible }) => (
  <div>{visible ? visible.get('content') : 'hidden'}</div>
));

describe('filter expiry tick', () => {
  beforeEach(() => {
    jest.useFakeTimers('modern');
    jest.setSystemTime(new Date('2026-11-15T00:00:00.000Z'));
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('shows an already rendered post when the mute expires without moving the timeline or unread state', () => {
    const store = createStore(rootReducer, applyMiddleware(thunk));
    const expiresAt = new Date('2026-11-15T00:00:05.000Z').toISOString();

    store.dispatch(importFetchedStatus(status));
    store.dispatch({
      type: FILTERS_FETCH_SUCCESS,
      filters: [{
        id: '1',
        title: '#番組',
        context: ['home'],
        filter_action: 'hide',
        expires_at: expiresAt,
        keywords: [{ id: '10', keyword: 'unused', whole_word: false }],
        statuses: [],
        tags: [{ id: '7', name: '番組' }],
      }],
      skipLoading: true,
    });
    store.dispatch({ type: TIMELINE_UPDATE, timeline: 'home', status: { id: '101' } });
    armFilterExpiry(store.dispatch, store.getState);

    render(
      <Provider store={store}>
        <Row id='101' contextType='home' />
      </Provider>,
    );

    expect(screen.getByText('hidden')).toBeTruthy();

    const before = store.getState();
    const timeline = before.get('timelines');
    const notifications = before.get('notifications');
    const generation = before.getIn(['filterMatches', 'generation']);
    const items = before.getIn(['timelines', 'home', 'items']);

    expect(items.includes('101') || items.includes(101)).toBe(true);
    expect(before.get('filterClock')).toBe(0);

    act(() => {
      jest.advanceTimersByTime(4999);
    });
    expect(screen.getByText('hidden')).toBeTruthy();
    expect(store.getState().get('filterClock')).toBe(0);

    act(() => {
      jest.advanceTimersByTime(1);
    });

    expect(screen.getByText('<p>live post</p>')).toBeTruthy();
    const after = store.getState();
    expect(after.get('filterClock')).toBe(1);
    expect(after.get('timelines')).toBe(timeline);
    expect(after.get('notifications')).toBe(notifications);
    expect(after.getIn(['filterMatches', 'generation'])).toBe(generation);
    expect(after.get('statuses')).toBe(before.get('statuses'));
    expect(after.get('filters')).toBe(before.get('filters'));
    expect(after.getIn(['timelines', 'home', 'items'])).toBe(items);
    expect(store.getState().getIn(['notifications', 'unread'])).toBe(before.getIn(['notifications', 'unread']));
  });

  it('changes root state when the expiry action is reduced', () => {
    const store = createStore(rootReducer);
    const previous = store.getState();

    store.dispatch({ type: FILTERS_EXPIRY_TICK, skipLoading: true });

    expect(store.getState()).not.toBe(previous);
    expect(store.getState().get('filterClock')).toBe(1);
    expect(store.getState().get('timelines')).toBe(previous.get('timelines'));
    expect(store.getState().get('notifications')).toBe(previous.get('notifications'));
    expect(store.getState().get('filterMatches')).toBe(previous.get('filterMatches'));
  });
});
