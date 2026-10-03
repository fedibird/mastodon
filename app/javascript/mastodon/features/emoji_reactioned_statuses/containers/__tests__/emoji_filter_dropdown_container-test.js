/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';
import { fromJS } from 'immutable';

jest.mock('react-intl', () => {
  const interpolate = (defaultMessage, values) => {
    if (!values) {
      return defaultMessage;
    }

    return defaultMessage.split(/\{(\w+)\}/g).map((part, index) => (
      index % 2 === 1 ? values[part] : part
    )).join('');
  };
  const intl = {
    formatMessage: ({ defaultMessage }, values) => interpolate(defaultMessage, values),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => interpolate(defaultMessage, values),
  };
});

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

jest.mock('mastodon/components/emoji', () => {
  const React = require('react');

  return function Emoji({ emoji, url, domain }) {
    return <img alt={emoji} data-url={url || ''} data-domain={domain || ''} />;
  };
});

jest.mock('mastodon/is_mobile', () => ({
  isUserTouching: jest.fn(() => false),
}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({
    put: jest.fn(() => Promise.resolve({})),
    get: jest.fn(() => Promise.resolve({ data: [] })),
  })),
}));

import { isUserTouching } from 'mastodon/is_mobile';
import { SETTING_CHANGE } from 'mastodon/actions/settings';
import { COLUMN_PARAMS_CHANGE } from 'mastodon/actions/columns';
import { DROPDOWN_MENU_OPEN } from 'mastodon/actions/dropdown_menu';
import { MODAL_OPEN } from 'mastodon/actions/modal';
import dropdownMenu from 'mastodon/reducers/dropdown_menu';
import modal from 'mastodon/reducers/modal';
import EmojiFilterDropdownContainer from '../emoji_filter_dropdown_container';

const catalog = {
  items: [
    { name: '🎉', custom: false, domain: null, count: 8 },
    { name: '👍', custom: false, domain: null, count: 5 },
    { name: '🥳', custom: false, domain: null, count: 2 },
  ],
  loaded: true,
  isLoading: false,
  stale: false,
  error: null,
};

const buildState = (emojis = []) => fromJS({
  settings: {
    emoji_reactioned_statuses: { emojis },
    columns: [
      { uuid: 'column-a', params: { emojis: ['👍'] } },
      { uuid: 'column-b', params: { emojis: ['🎉', '🥳'] } },
    ],
  },
  emoji_reactioned_statuses: { catalog },
}).set('dropdown_menu', dropdownMenu(undefined, { type: '@@INIT' }))
  .set('modal', modal(undefined, { type: '@@INIT' }));

const createHarness = (emojis = []) => {
  const actions = [];
  const record = () => next => action => {
    if (action && action.type) {
      actions.push(action);
    }

    return next(action);
  };
  const reducer = (state = buildState(emojis), action) => {
    let settings = state.get('settings');

    if (action.type === SETTING_CHANGE) {
      settings = settings.setIn(action.path, action.value);
    }

    if (action.type === COLUMN_PARAMS_CHANGE) {
      settings = settings.update('columns', columns => columns.map(column => (
        column.get('uuid') === action.uuid ? column.setIn(['params', ...action.path], action.value) : column
      )));
    }

    return state
      .set('settings', settings)
      .set('dropdown_menu', dropdownMenu(state.get('dropdown_menu'), action))
      .set('modal', modal(state.get('modal'), action));
  };

  return {
    actions,
    store: createStore(reducer, buildState(emojis), applyMiddleware(record, thunk)),
  };
};

const renderFilter = (columnId, emojis) => {
  const harness = createHarness(emojis);

  render(
    <Provider store={harness.store}>
      <EmojiFilterDropdownContainer columnId={columnId} />
    </Provider>,
  );

  return harness;
};

describe('EmojiFilterDropdownContainer', () => {
  beforeEach(() => {
    isUserTouching.mockReturnValue(false);
  });

  it('opens a desktop dropdown', () => {
    const { actions } = renderFilter(undefined, []);

    fireEvent.click(screen.getByRole('button', { name: 'Filter by emoji' }));

    expect(actions.map(action => action.type)).toContain(DROPDOWN_MENU_OPEN);
    expect(actions.map(action => action.type)).not.toContain(MODAL_OPEN);
    expect(screen.getByRole('dialog')).toBeInTheDocument();
  });

  it('opens the touch modal instead of a dropdown', () => {
    isUserTouching.mockReturnValue(true);
    const { actions } = renderFilter('column-a', []);
    const modalAction = actions.find(action => action.type === MODAL_OPEN);

    fireEvent.click(screen.getByRole('button', { name: 'Filter by emoji' }));

    const opened = actions.find(action => action.type === MODAL_OPEN);

    expect(modalAction).toBeUndefined();
    expect(opened.modalType).toBe('EMOJI_REACTION_FILTER');
    expect(opened.modalProps.columnId).toBe('column-a');
    expect(actions.map(action => action.type)).not.toContain(DROPDOWN_MENU_OPEN);
  });

  it('applies the default page filter through settings and does not fetch again', () => {
    const { actions, store } = renderFilter(undefined, ['🎉']);

    fireEvent.click(screen.getByRole('button', { name: 'Filter by emoji' }));
    fireEvent.click(screen.getByRole('button', { name: '👍' }));
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));

    const change = actions.find(action => action.type === SETTING_CHANGE);

    expect(change.path).toEqual(['emoji_reactioned_statuses', 'emojis']);
    expect(change.value.toJS()).toEqual(['🎉', '👍']);
    expect(actions.map(action => action.type)).not.toContain('EMOJI_REACTIONED_STATUSES_FETCH_REQUEST');
    expect(store.getState().getIn(['settings', 'columns', 1, 'params', 'emojis']).toJS()).toEqual(['🎉', '🥳']);
  });

  it('closes the open desktop picker when a filter chip is removed', () => {
    const { actions } = renderFilter(undefined, ['🎉', '👍']);

    fireEvent.click(screen.getByRole('button', { name: 'Filter by emoji' }));
    expect(screen.getByRole('dialog')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '🎉' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'true');

    fireEvent.click(screen.getByRole('button', { name: 'Remove 🎉 from emoji filter' }));

    const change = actions.find(action => action.type === SETTING_CHANGE);

    expect(change.path).toEqual(['emoji_reactioned_statuses', 'emojis']);
    expect(change.value.toJS()).toEqual(['👍']);
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Filter by emoji' }));

    expect(screen.getByRole('button', { name: '🎉' })).toHaveAttribute('aria-pressed', 'false');
    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: 'Apply' })).toBeDisabled();
  });

  it('applies a pinned column filter without changing another column', () => {
    const { actions, store } = renderFilter('column-a', ['🎉']);

    fireEvent.click(screen.getByRole('button', { name: 'Filter by emoji' }));
    fireEvent.click(screen.getByRole('button', { name: '🎉' }));
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));

    const change = actions.find(action => action.type === COLUMN_PARAMS_CHANGE);

    expect(change.uuid).toBe('column-a');
    expect(change.path).toEqual(['emojis']);
    expect(change.value.toJS()).toEqual(['👍', '🎉']);
    expect(store.getState().getIn(['settings', 'emoji_reactioned_statuses', 'emojis']).toJS()).toEqual(['🎉']);
    expect(store.getState().getIn(['settings', 'columns', 1, 'params', 'emojis']).toJS()).toEqual(['🎉', '🥳']);
    expect(actions.map(action => action.type)).not.toContain(SETTING_CHANGE);
  });
});
