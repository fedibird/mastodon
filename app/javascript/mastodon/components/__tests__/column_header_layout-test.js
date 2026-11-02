import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('mastodon/initial_state', () => ({
  enableEmptyColumn: false,
  defaultColumnWidth: 'x100',
}));

jest.mock('mastodon/components/icon', () => {
  const ReactMock = require('react');
  return () => ReactMock.createElement('span');
});

jest.mock('react-intl', () => {
  const ReactMock = require('react');

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => ReactMock.createElement(Component, {
      ...props,
      intl: { formatMessage: message => message.defaultMessage || message.id },
    }),
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

// Prevent settings persistence from making an API request; exercise the real
// changeColumnParams action, including its path shape.
jest.mock('mastodon/actions/settings', () => ({
  changeSetting: (path, value) => ({ type: 'SETTING_CHANGE', path, value }),
  saveSettings: () => ({ type: 'SETTING_SAVE' }),
}));

import ColumnHeader from '../column_header';

const makeStore = () => {
  const initialState = fromJS({
    settings: {
      home: { layoutMode: 'card-1' },
      columns: [{ uuid: 'pinned-home', params: { layoutMode: 'card-2' } }],
    },
  });

  const reducer = (state = initialState, action) => {
    if (action.type === 'COLUMN_PARAMS_CHANGE') {
      const index = state.getIn(['settings', 'columns']).findIndex(column => column.get('uuid') === action.uuid);

      return state.setIn(['settings', 'columns', index, 'params', ...action.path], action.value);
    }

    if (action.type === 'SETTING_CHANGE') {
      return state.setIn(['settings', ...action.path], action.value);
    }

    return state;
  };

  return createStore(reducer, applyMiddleware(thunk));
};

const renderHeader = (store, columnId) => render(
  <Provider store={store}>
    <ColumnHeader
      title='Home'
      icon='home'
      columnId={columnId}
      layoutScope='home'
      multiColumn
      pinned={!!columnId}
      columnWidth='x100'
      onPin={() => {}}
      onMove={() => {}}
      onClick={() => {}}
    />
  </Provider>,
);

describe('ColumnHeader layout selector', () => {
  it('renders and updates the standalone timeline setting when columnId is absent', () => {
    const store = makeStore();
    renderHeader(store);

    fireEvent.click(screen.getByRole('button', { name: 'Show settings' }));
    const control = screen.getByRole('combobox', { name: 'Display mode' });

    expect(control).toHaveValue('card-1');
    expect(control).toHaveAttribute('id', 'column-layout-home');

    fireEvent.change(control, { target: { value: 'media' } });

    expect(store.getState().getIn(['settings', 'home', 'layoutMode'])).toBe('media');
    expect(store.getState().getIn(['settings', 'columns', 0, 'params', 'layoutMode'])).toBe('card-2');
  });

  it('renders and updates a pinned column without changing the standalone setting', () => {
    const store = makeStore();
    renderHeader(store, 'pinned-home');

    fireEvent.click(screen.getByRole('button', { name: 'Show settings' }));
    const control = screen.getByRole('combobox', { name: 'Display mode' });

    expect(control).toHaveValue('card-2');
    expect(control).toHaveAttribute('id', 'column-layout-pinned-home');

    fireEvent.change(control, { target: { value: 'card-3' } });

    expect(store.getState().getIn(['settings', 'columns', 0, 'params', 'layoutMode'])).toBe('card-3');
    expect(store.getState().getIn(['settings', 'home', 'layoutMode'])).toBe('card-1');
  });
});
