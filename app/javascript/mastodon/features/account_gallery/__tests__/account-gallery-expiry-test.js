/* eslint-disable react/prop-types */

import React from 'react';
import { act } from 'react-dom/test-utils';
import { Provider } from 'react-redux';
import { createStore, applyMiddleware } from 'redux';
import { render, screen } from '@testing-library/react';
import { IntlProvider } from 'react-intl';
import thunk from 'redux-thunk';

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: () => ({
    get: () => new Promise(() => {}),
    post: () => new Promise(() => {}),
  }),
  getLinks: () => ({ refs: [] }),
}));
jest.mock('mastodon/initial_state', () => ({
  me: 'me',
  maxFrequentlyUsedEmojis: 16,
  displayMedia: 'default',
  useBlurhash: false,
  autoPlayMedia: false,
  defaultColumnWidth: 'wide',
}));
jest.mock('../../account_timeline/containers/header_container', () => () => null);
jest.mock('../../account_timeline/containers/column_settings_container', () => () => null);
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/containers/scroll_container', () => ({ children }) => children);
jest.mock('mastodon/components/missing_indicator', () => () => null);
jest.mock('mastodon/components/column_header', () => ({ children }) => <div>{children}</div>);

import rootReducer from 'mastodon/reducers';
import { importFetchedAccount, importFetchedStatus } from 'mastodon/actions/importer';
import { expandTimelineSuccess } from 'mastodon/actions/timelines';
import { FILTERS_FETCH_SUCCESS } from 'mastodon/actions/filters';
import { armFilterExpiry } from 'mastodon/actions/filter_expiry';
import AccountGallery from '../index';

const other = {
  id: 'other',
  acct: 'other',
  username: 'other',
  display_name: 'Other',
  note: '',
  url: 'https://example.com/@other',
  emojis: [],
};

const image = (id, description, preview) => ({
  id,
  type: 'image',
  description,
  preview_url: preview,
  meta: {},
});

const status = (id, attachment, extra) => ({
  id,
  account: other,
  content: '<p>photo</p>',
  spoiler_text: '',
  sensitive: false,
  visibility: 'public',
  url: `https://example.com/statuses/${id}`,
  media_attachments: [attachment],
  emojis: [],
  mentions: [],
  tags: [],
  filtered: [],
  reblog: null,
  quote: null,
  poll: null,
  ...extra,
});

describe('AccountGallery timed mute expiry', () => {
  afterEach(() => {
    jest.useRealTimers();
  });

  it('shows a hidden profile image again when the shared expiry tick fires', () => {
    jest.useFakeTimers('modern');
    jest.setSystemTime(new Date('2026-11-17T00:00:00.000Z'));

    const store = createStore(rootReducer, applyMiddleware(thunk));
    const matched = status('201', image('m-match', 'matched photo', '/matched.jpg'), {
      tags: [{ name: '番組', url: 'https://example.com/tags/番組' }],
      filtered: [{ filter: '1' }],
    });
    const control = status('200', image('m-control', 'control photo', '/control.jpg'));

    store.dispatch(importFetchedAccount(other));
    store.dispatch(importFetchedStatus(matched));
    store.dispatch(importFetchedStatus(control));
    store.dispatch(expandTimelineSuccess('account:other:media', [matched, control], null, false, false, false, false));
    store.dispatch({
      type: FILTERS_FETCH_SUCCESS,
      filters: [{
        id: '1',
        title: '#番組',
        context: ['account'],
        filter_action: 'hide',
        expires_at: '2026-11-17T00:00:05.000Z',
        keywords: [],
        statuses: [],
        tags: [{ id: '7', name: '番組' }],
      }],
      skipLoading: true,
    });
    armFilterExpiry(store.dispatch, store.getState);

    act(() => {
      render(
        <Provider store={store}>
          <IntlProvider locale='en'>
            <AccountGallery params={{ accountId: 'other' }} />
          </IntlProvider>
        </Provider>,
      );
    });

    expect(screen.queryByRole('img', { name: 'matched photo' })).toBeNull();
    expect(screen.getByRole('img', { name: 'control photo' })).toBeTruthy();

    const statuses = store.getState().get('statuses');
    const items = store.getState().getIn(['timelines', 'account:other:media', 'items']);
    const generation = store.getState().getIn(['filterMatches', 'generation']);

    act(() => {
      jest.advanceTimersByTime(5000);
    });

    expect(screen.getByRole('img', { name: 'matched photo' })).toHaveAttribute('src', '/matched.jpg');
    expect(screen.getByRole('img', { name: 'control photo' })).toHaveAttribute('src', '/control.jpg');
    expect(store.getState().get('statuses')).toBe(statuses);
    expect(store.getState().getIn(['timelines', 'account:other:media', 'items'])).toBe(items);
    expect(store.getState().getIn(['filterMatches', 'generation'])).toBe(generation);
    expect(store.getState().get('filterClock')).toBe(1);
  });
});
