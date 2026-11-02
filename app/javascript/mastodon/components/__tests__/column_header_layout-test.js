import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider, useSelector } from 'react-redux';
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
      home: { layoutMode: 'card-1', columnWidth: 'x100', other: { preserve: true } },
      columns: [
        { uuid: 'pinned-home', params: { layoutMode: 'card-2', columnWidth: 'x100', other: { preserve: true } } },
        { uuid: 'wide-home', params: { layoutMode: 'normal', columnWidth: 'x200', other: { preserve: true } } },
        { uuid: 'free-home', params: { layoutMode: 'normal', columnWidth: 'free', other: { preserve: true } } },
        { uuid: 'narrow-home', params: { layoutMode: 'normal', columnWidth: 'x080', other: { preserve: true } } },
      ],
    },
  });

  const actions = [];
  const reducer = (state = initialState, action) => {
    actions.push(action);

    if (action.type === 'COLUMN_PARAMS_CHANGE') {
      const index = state.getIn(['settings', 'columns']).findIndex(column => column.get('uuid') === action.uuid);

      return state.setIn(['settings', 'columns', index, 'params', ...action.path], action.value);
    }

    if (action.type === 'SETTING_CHANGE') {
      return state.setIn(['settings', ...action.path], action.value);
    }

    return state;
  };

  const store = createStore(reducer, applyMiddleware(thunk));
  store.actions = actions;
  return store;
};

const HeaderHarness = ({ columnId, multiColumn = true }) => {
  const columnWidth = useSelector(state => {
    if (!columnId) {
      return state.getIn(['settings', 'home', 'columnWidth']);
    }

    const column = state.getIn(['settings', 'columns']).find(entry => entry.get('uuid') === columnId);
    return column && column.getIn(['params', 'columnWidth']);
  });

  return (
    <ColumnHeader
      title='Home'
      icon='home'
      columnId={columnId}
      layoutScope='home'
      multiColumn={multiColumn}
      pinned={!!columnId}
      columnWidth={columnWidth}
      onPin={() => {}}
      onMove={() => {}}
      onClick={() => {}}
    />
  );
};

HeaderHarness.propTypes = {
  columnId: require('prop-types').string,
  multiColumn: require('prop-types').bool,
};

const renderHeader = (store, columnId, multiColumn) => {
  // Single-column headers portal into the tab bar, which must exist before
  // the first render to avoid the component's deferred portal re-render.
  if (multiColumn === false && !document.getElementById('tabs-bar__portal')) {
    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
  }

  return render(
    <Provider store={store}>
      <HeaderHarness columnId={columnId} multiColumn={multiColumn} />
    </Provider>,
  );
};

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
    expect(store.getState().getIn(['settings', 'home', 'columnWidth'])).toBe('x100');
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
    expect(store.getState().getIn(['settings', 'columns', 0, 'params', 'columnWidth'])).toBe('x200');
    expect(store.getState().getIn(['settings', 'columns', 0, 'params', 'other', 'preserve'])).toBe(true);
    expect(store.getState().getIn(['settings', 'home', 'layoutMode'])).toBe('card-1');
  });

  it('upgrades a standalone advanced column in one settings action', () => {
    const store = makeStore();
    renderHeader(store);

    fireEvent.click(screen.getByRole('button', { name: 'Show settings' }));
    fireEvent.change(screen.getByRole('combobox', { name: 'Display mode' }), { target: { value: 'card-2' } });

    expect(store.getState().getIn(['settings', 'home', 'layoutMode'])).toBe('card-2');
    expect(store.getState().getIn(['settings', 'home', 'columnWidth'])).toBe('x125');
    expect(store.getState().getIn(['settings', 'home', 'other', 'preserve'])).toBe(true);
    expect(store.actions.filter(action => action.type === 'SETTING_CHANGE')).toHaveLength(1);
  });

  it('does not resize a standalone column outside advanced multi-column mode', () => {
    const store = makeStore();
    renderHeader(store, undefined, false);

    fireEvent.click(screen.getByRole('button', { name: 'Show settings' }));
    fireEvent.change(screen.getByRole('combobox', { name: 'Display mode' }), { target: { value: 'card-3' } });

    expect(store.getState().getIn(['settings', 'home', 'layoutMode'])).toBe('card-3');
    expect(store.getState().getIn(['settings', 'home', 'columnWidth'])).toBe('x100');
  });

  it('resizes a narrow fixed column to 125% for two cards', () => {
    const store = makeStore();
    renderHeader(store, 'narrow-home');

    fireEvent.click(screen.getByRole('button', { name: 'Show settings' }));
    fireEvent.change(screen.getByRole('combobox', { name: 'Display mode' }), { target: { value: 'card-2' } });

    expect(store.getState().getIn(['settings', 'columns', 3, 'params', 'layoutMode'])).toBe('card-2');
    expect(store.getState().getIn(['settings', 'columns', 3, 'params', 'columnWidth'])).toBe('x125');
    expect(store.actions.filter(action => action.type === 'COLUMN_PARAMS_CHANGE')).toHaveLength(1);
  });

  it.each(['wide-home', 'free-home'])('preserves sufficient or free width in %s', columnId => {
    const store = makeStore();
    renderHeader(store, columnId);

    const existing = store.getState().get('settings').get('columns').find(col => col.get('uuid') === columnId).getIn(['params', 'columnWidth']);
    fireEvent.click(screen.getByRole('button', { name: 'Show settings' }));
    fireEvent.change(screen.getByRole('combobox', { name: 'Display mode' }), { target: { value: 'card-3' } });

    const params = store.getState().get('settings').get('columns').find(col => col.get('uuid') === columnId).get('params');
    expect(params.get('layoutMode')).toBe('card-3');
    expect(params.get('columnWidth')).toBe(existing);
    expect(params.getIn(['other', 'preserve'])).toBe(true);
  });

  it('does not reduce column width when switching back to normal', () => {
    const store = makeStore();
    renderHeader(store, 'wide-home');

    fireEvent.click(screen.getByRole('button', { name: 'Show settings' }));
    fireEvent.change(screen.getByRole('combobox', { name: 'Display mode' }), { target: { value: 'card-2' } });
    fireEvent.change(screen.getByRole('combobox', { name: 'Display mode' }), { target: { value: 'normal' } });

    expect(store.getState().getIn(['settings', 'columns', 1, 'params', 'columnWidth'])).toBe('x200');
    expect(store.getState().getIn(['settings', 'columns', 1, 'params', 'layoutMode'])).toBe('normal');
  });
});
