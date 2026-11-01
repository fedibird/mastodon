jest.mock('react-intl', () => {
  const React = require('react');
  const formatMessage = ({ defaultMessage }) => defaultMessage;

  return {
    defineMessages: (messages) => messages,
    injectIntl: (Component) => (props) => React.createElement(Component, { ...props, intl: { formatMessage } }),
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('react-router-scroll-4', () => ({
  ScrollContainer: ({ children }) => children,
}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('mastodon/actions/importer', () => ({
  importFetchedAccounts: jest.fn(accounts => ({ type: 'ACCOUNTS_IMPORT', accounts })),
}));

jest.mock('../components/account_card', () => {
  const React = require('react');
  const PropTypes = require('prop-types');

  const AccountCard = (props) => React.createElement('article', { 'data-testid': 'group', 'data-id': props.id }, props.id);
  AccountCard.propTypes = { id: PropTypes.string };

  return AccountCard;
});

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import api from 'mastodon/api';
import userLists from 'mastodon/reducers/user_lists';
import GroupDirectory from '../index';

const identity = (state = ImmutableMap()) => state;

const page = (start, count) => Array.from({ length: count }, (_, index) => ({
  id: String(start + index),
  group_directory: { software: 'fedibird', languages: [], capabilities: { posting: null } },
}));

const makeStore = () => createStore(combineReducers({
  user_lists: userLists,
  settings: identity,
  relationships: identity,
}), ImmutableMap({
  settings: ImmutableMap(),
  relationships: ImmutableMap(),
}), applyMiddleware(thunk));

const directory = (store) => store.getState().getIn(['user_lists', 'group_directories', 'route']);

const groupIds = () => screen.queryAllByTestId('group').map(node => node.getAttribute('data-id'));

describe('GroupDirectory paging', () => {
  let pending;

  beforeEach(() => {
    pending = [];
    document.body.innerHTML = '<div id="tabs-bar__portal"></div>';
    api.mockReset();
    api.mockImplementation(() => ({
      get: (url, config) => {
        if (String(url).includes('relationships')) {
          return Promise.resolve({ data: [] });
        }

        let resolve;
        let reject;
        const promise = new Promise((res, rej) => {
          resolve = res;
          reject = rej;
        });
        pending.push({ url, config, resolve, reject });
        return promise;
      },
    }));
  });

  const renderDirectory = (store) => render(
    <Provider store={store}>
      <GroupDirectory multiColumn={false} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }} />
    </Provider>,
  );

  it('retries the same extra page and leaves the groups already on screen', async () => {
    const store = makeStore();
    renderDirectory(store);

    await waitFor(() => expect(pending).toHaveLength(1));
    expect(pending[0].config.params.offset).toBeUndefined();
    pending[0].resolve({ data: page(1, 20) });

    await waitFor(() => expect(groupIds()).toHaveLength(20));
    fireEvent.click(screen.getByRole('button', { name: 'Load more' }));

    await waitFor(() => expect(pending).toHaveLength(2));
    expect(pending[1].config.params.offset).toBe(20);
    pending[1].reject(new Error('500'));

    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('The group directory could not be loaded'));
    expect(groupIds()).toEqual(page(1, 20).map(account => account.id));
    expect(directory(store).get('failure')).toBe('expand');
    expect(directory(store).get('nextOffset')).toBe(20);

    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    await waitFor(() => expect(pending).toHaveLength(3));
    expect(pending[2].config.params.offset).toBe(20);
    expect(groupIds()).toHaveLength(20);
    expect(directory(store).get('items').size).toBe(20);
    pending[2].resolve({ data: page(21, 20) });

    await waitFor(() => expect(groupIds()).toHaveLength(40));
    expect(screen.queryByRole('alert')).toBeNull();
    expect(directory(store).get('nextOffset')).toBe(40);
    expect(directory(store).get('failure')).toBe(null);
  });

  it('retries a failed first page from the start', async () => {
    const store = makeStore();
    renderDirectory(store);

    await waitFor(() => expect(pending).toHaveLength(1));
    pending[0].reject(new Error('500'));

    await waitFor(() => expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy());
    expect(groupIds()).toEqual([]);
    expect(directory(store).get('failure')).toBe('fetch');
    expect(directory(store).get('items').size).toBe(0);

    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    await waitFor(() => expect(pending).toHaveLength(2));
    expect(pending[1].config.params.offset).toBeUndefined();
    expect(groupIds()).toEqual([]);
    pending[1].resolve({ data: page(1, 2) });

    await waitFor(() => expect(groupIds()).toEqual(['1', '2']));
    expect(directory(store).get('nextOffset')).toBe(2);
    expect(directory(store).get('failure')).toBe(null);
    expect(screen.queryByRole('alert')).toBeNull();
  });
});
