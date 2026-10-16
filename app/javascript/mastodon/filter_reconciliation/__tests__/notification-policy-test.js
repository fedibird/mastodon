/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { Provider } from 'react-redux';
import { render, act, fireEvent } from '@testing-library/react';
import { fromJS } from 'immutable';
import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({ defineMessages: messages => messages, injectIntl: Component => Component, FormattedMessage: ({ defaultMessage }) => defaultMessage }));
jest.mock('intl-messageformat', () => function IntlMessageFormat() {
  return { format: () => 'title' };
});
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));
jest.mock('../../api', () => ({ __esModule: true, default: jest.fn(), getLinks: jest.fn() }));
jest.mock('../../initial_state', () => ({ me: 'me', maxFrequentlyUsedEmojis: 16 }));
jest.mock('mastodon/features/emoji/emoji', () => ({ __esModule: true, default: text => text || '', buildCustomEmojis: () => [], categoriesFromEmojis: () => [] }));
jest.mock('../../components/status', () => ({ status, onFavourite }) => status ? <button data-status={status.get('id')} data-warn={!!status.get('matched_filters')} onClick={() => onFavourite(status)}>post</button> : null);
jest.mock('react-hotkeys', () => ({ HotKeys: ({ handlers, children }) => <div><button data-hotkey onClick={handlers.favourite}>hotkey</button>{children}</div> }));
jest.mock('../../actions/interactions', () => ({ favourite: jest.fn(() => ({ type: 'TEST_FAVOURITE' })) }));

import rootReducer from '../../reducers';
import NotificationContainer from '../../features/notifications/containers/notification_container';
import { importFetchedStatus, importFetchedAccount } from '../../actions/importer';
import { favourite } from '../../actions/interactions';
import { filterReconciliationMiddleware } from '../scheduler';

const intl = { formatMessage: ({ defaultMessage }) => defaultMessage, formatDate: () => 'today' };
const definition = action => ({ id: '1', title: 'notice', context: ['notifications'], filter_action: action, expires_at: null, keywords: [], statuses: [] });
const account = id => ({ id, acct: id, username: id, display_name: id, note: '', url: `https://example.test/@${id}`, emojis: [] });
const snapshot = (store, action) => store.dispatch({ type: 'FILTERS_FETCH_SUCCESS', filters: action ? [definition(action)] : [], receivedAt: Date.now() });
const setup = (type, own = false) => {
  const store = createStore(rootReducer, applyMiddleware(thunk, filterReconciliationMiddleware));
  store.dispatch(importFetchedStatus({ id: '101', account: account(own ? 'me' : 'other'), content: 'hello', spoiler_text: '', media_attachments: [], emojis: [], mentions: [], tags: [], filtered: [{ filter: definition('hide') }], reblog: null, quote: null, poll: null }));
  store.dispatch(importFetchedAccount(account('other')));
  snapshot(store, null);
  const notification = fromJS({ id: '9001', type, status: '101', account: 'other', created_at: '2026-10-16', emoji_reaction: { name: 'heart' } });
  const view = render(<Provider store={store}><NotificationContainer notification={notification} accountId='other' intl={intl} onMoveUp={() => {}} onMoveDown={() => {}} /></Provider>);
  return { store, view };
};
afterEach(() => favourite.mockClear());

it.each(['status', 'mention', 'poll', 'favourite', 'reblog', 'scheduled_status', 'emoji_reaction', 'status_reference', 'update'])('keeps %s display, warnings and hotkey policy consistent when existing notifications change', type => {
  const { store, view } = setup(type);
  const notifications = store.getState().get('notifications');
  expect(view.container.querySelector('[data-status]')).not.toBeNull();
  if (type !== 'mention') {
    fireEvent.click(view.container.querySelector('[data-hotkey]'));
    expect(favourite).toHaveBeenCalledTimes(1); favourite.mockClear();
  }
  act(() => snapshot(store, 'hide'));
  expect(view.container.querySelector('[data-status]')).toBeNull();
  if (type !== 'mention') {
    expect(view.container.querySelector('.notification__message')).not.toBeNull();
    fireEvent.click(view.container.querySelector('[data-hotkey]'));
    expect(favourite).not.toHaveBeenCalled();
  } else expect(view.container.textContent).toBe('');
  act(() => snapshot(store, 'warn'));
  expect(view.container.querySelector('[data-status]')).toHaveAttribute('data-warn', 'true');
  if (type !== 'mention') {
    fireEvent.click(view.container.querySelector('[data-hotkey]'));
    expect(favourite.mock.calls[0][0].get('matched_filters').toJS()).toEqual(['notice']);
    favourite.mockClear();
  }
  // Mention uses the nested StatusContainer's own actions, with the same selector.
  fireEvent.click(view.container.querySelector('[data-status]'));
  expect(favourite.mock.calls[0][0].get('matched_filters').toJS()).toEqual(['notice']);
  act(() => snapshot(store, null));
  expect(view.container.querySelector('[data-status]')).toHaveAttribute('data-warn', 'false');
  expect(store.getState().get('notifications')).toBe(notifications);
});

it.each(['favourite', 'reblog'])('preserves self-post exclusion for %s display and hotkeys', type => {
  const { store, view } = setup(type, true);
  act(() => snapshot(store, 'hide'));
  expect(view.container.querySelector('[data-status]')).not.toBeNull();
  fireEvent.click(view.container.querySelector('[data-hotkey]'));
  expect(favourite.mock.calls[0][0].getIn(['account', 'id'])).toBe('me');
});
