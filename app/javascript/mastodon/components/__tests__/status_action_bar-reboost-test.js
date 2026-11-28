/* eslint-disable react/prop-types */

import { act, fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import PropTypes from 'prop-types';
import { Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('../../initial_state', () => ({
  me: 'me',
  isStaff: false,
  show_bookmark_button: true,
  show_quote_button: true,
  show_share_button: false,
  enableReaction: true,
  compactReaction: false,
  enableStatusReference: true,
  maxReferences: 5,
  matchVisibilityOfReferences: false,
  addReferenceModal: false,
  disablePost: false,
  disableReactions: false,
  disableBlock: false,
  disableDomainBlock: false,
  disableReport: false,
  enableReboost: true,
}));

jest.mock('../../is_mobile', () => ({
  isUserTouching: jest.fn(() => false),
  isMobile: () => false,
  layoutFromWindow: () => 'multi-column',
  isIOS: () => false,
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) return defaultMessage;
      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]);
    },
    now: () => Date.now(),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../../containers/reaction_picker_dropdown_container', () => () => <div data-testid='emoji-reaction' />);

import { isUserTouching } from '../../is_mobile';
import statuses from '../../reducers/statuses';
import { REBOOST_OPERATION } from '../../actions/interactions';
import StatusActionBar from '../status_action_bar';

const root = (state, action) => {
  const current = state || ImmutableMap({
    relationships: ImmutableMap({ other: ImmutableMap() }),
    compose: ImmutableMap({ references: ImmutableSet(), privacy: 'public' }),
    dropdown_menu: ImmutableMap(),
    statuses: ImmutableMap({ s1: ImmutableMap({ id: 's1', reblogged: true }) }),
    modal: ImmutableMap(),
  });
  let next = current.set('statuses', statuses(current.get('statuses'), action));

  if (action.type === 'DROPDOWN_MENU_OPEN') {
    next = next.setIn(['dropdown_menu', 'openId'], action.id).setIn(['dropdown_menu', 'keyboard'], Boolean(action.keyboard));
  } else if (action.type === 'DROPDOWN_MENU_CLOSE') {
    next = next.setIn(['dropdown_menu', 'openId'], null);
  } else if (action.type === 'MODAL_OPEN') {
    next = next.set('modal', ImmutableMap({ modalType: action.modalType, modalProps: action.modalProps }));
  } else if (action.type === 'MODAL_CLOSE') {
    next = next.set('modal', ImmutableMap());
  }

  return next;
};

class RouterProvider extends React.Component {

  static childContextTypes = {
    router: PropTypes.object,
  };

  getChildContext () {
    return { router: { history: { push: jest.fn() } } };
  }

  render () {
    return this.props.children;
  }

}

const buildStatus = (overrides = {}) => fromJS({
  id: 's1',
  account: { id: 'other', acct: 'bob', username: 'bob', url: 'https://example.test/bob' },
  visibility: 'public',
  muted: false,
  reblogged: true,
  favourited: false,
  bookmarked: false,
  reblogs_count: 1,
  favourites_count: 0,
  replies_count: 0,
  status_referred_by_count: 0,
  emoji_reactions_count: 0,
  emoji_reactions: [],
  url: 'https://example.test/s1',
  expires_at: null,
  reblog: null,
  ...overrides,
});

const renderBar = (status, props = {}) => {
  const store = createStore(root, applyMiddleware(thunk));
  const onReboost = jest.fn();
  const onUnreblog = jest.fn();
  const onReblog = jest.fn();
  const view = render(
    <Provider store={store}>
      <RouterProvider>
        <StatusActionBar
          status={status}
          onReply={jest.fn()}
          onFavourite={jest.fn()}
          onReblog={onReblog}
          onUnreblog={onUnreblog}
          onReboost={onReboost}
          onQuote={jest.fn()}
          onBookmark={jest.fn()}
          onEdit={jest.fn()}
          onDelete={jest.fn()}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          {...props}
        />
      </RouterProvider>
    </Provider>,
  );

  return { ...view, store, onReboost, onUnreblog, onReblog };
};

describe('StatusActionBar reboost menu', () => {
  beforeEach(() => {
    isUserTouching.mockReturnValue(false);
  });

  it('opens boost actions instead of unreblogging, by click and by keyboard', () => {
    const { onReblog } = renderBar(buildStatus());
    const trigger = screen.getByRole('button', { name: 'Boost actions' });

    expect(screen.queryByRole('button', { name: 'Unboost' })).not.toBeInTheDocument();
    expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
    expect(trigger).toHaveAttribute('aria-expanded', 'false');

    fireEvent.click(trigger);

    expect(trigger).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('button', { name: 'Reboost' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Unboost' })).toBeInTheDocument();
    expect(onReblog).not.toHaveBeenCalled();

    fireEvent.click(trigger);
    expect(trigger).toHaveAttribute('aria-expanded', 'false');

    fireEvent.keyPress(trigger, { key: 'Enter', charCode: 13 });
    expect(trigger).toHaveAttribute('aria-expanded', 'true');
  });

  it('sends one reboost and disables that item while the operation is open', () => {
    const { onReboost, store } = renderBar(buildStatus());

    fireEvent.click(screen.getByRole('button', { name: 'Boost actions' }));
    fireEvent.click(screen.getByRole('button', { name: 'Reboost' }));
    expect(onReboost).toHaveBeenCalledTimes(1);

    act(() => {
      store.dispatch({ type: REBOOST_OPERATION, statusId: 's1', operation: { id: '9', state: 'pending' } });
    });
    fireEvent.click(screen.getByRole('button', { name: 'Boost actions' }));

    const item = screen.getByRole('button', { name: 'Reboost' });
    expect(item).toHaveAttribute('aria-disabled', 'true');
    fireEvent.click(item);
    expect(onReboost).toHaveBeenCalledTimes(1);
  });

  it('keeps unreblog on the plain button when the post is not boosted', () => {
    const { onReblog } = renderBar(buildStatus({ reblogged: false }));
    const trigger = screen.getByRole('button', { name: 'Boost' });

    expect(trigger).not.toHaveAttribute('aria-haspopup');
    fireEvent.click(trigger);
    expect(onReblog).toHaveBeenCalledTimes(1);
  });

  it('hands the same actions to the touch modal', () => {
    isUserTouching.mockReturnValue(true);
    const { store, onReblog } = renderBar(buildStatus());

    fireEvent.click(screen.getByRole('button', { name: 'Boost actions' }));

    expect(onReblog).not.toHaveBeenCalled();
    expect(store.getState().getIn(['modal', 'modalType'])).toBe('ACTIONS');
    expect(store.getState().getIn(['modal', 'modalProps']).actions.map(action => action.text)).toEqual(expect.arrayContaining(['Reboost', 'Unboost']));
  });
});
