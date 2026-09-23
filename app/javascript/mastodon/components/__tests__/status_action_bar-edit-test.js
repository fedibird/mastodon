/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import React from 'react';
import PropTypes from 'prop-types';
import { Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

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

jest.mock('../../containers/dropdown_menu_container', () => ({ items }) => (
  <div data-testid='more-menu'>
    {(items || []).filter(Boolean).map((item, index) => (
      <button key={index} type='button' onClick={item.action}>{item.text}</button>
    ))}
  </div>
));
jest.mock('../../containers/reaction_picker_dropdown_container', () => () => <div data-testid='emoji-reaction' />);

import StatusActionBar from '../status_action_bar';

const store = createStore(() => ImmutableMap({
  relationships: ImmutableMap(),
  compose: ImmutableMap({
    references: ImmutableSet(),
    privacy: 'public',
  }),
}));

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
  account: {
    id: 'me',
    acct: 'alice',
    username: 'alice',
    url: 'https://example.test/alice',
  },
  visibility: 'public',
  muted: false,
  reblogged: false,
  favourited: false,
  bookmarked: false,
  reblogs_count: 0,
  favourites_count: 0,
  replies_count: 0,
  status_referred_by_count: 0,
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  emoji_reactions_count: 0,
  emoji_reactions: [],
  url: 'https://example.test/s1',
  expires_at: null,
  reblog: null,
  ...overrides,
});

const renderBar = (status, props = {}) => render(
  <Provider store={store}>
    <RouterProvider>
      <StatusActionBar
        status={status}
        onReply={jest.fn()}
        onFavourite={jest.fn()}
        onReblog={jest.fn()}
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

describe('StatusActionBar edit menu', () => {
  it('shows Edit on an own local status and keeps Delete & re-draft', () => {
    renderBar(buildStatus());

    expect(screen.getByRole('button', { name: 'Edit' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Delete' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Delete & re-draft' })).toBeInTheDocument();
  });

  it('does not show Edit on someone else\'s status', () => {
    renderBar(buildStatus({ account: { id: 'other', acct: 'bob', username: 'bob', url: 'https://example.test/bob' } }));

    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
  });

  it('does not show Edit on an expired status', () => {
    renderBar(buildStatus(), { expired: true });

    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Delete' })).toBeInTheDocument();
  });

  it('does not show Edit on a boost of someone else\'s status', () => {
    renderBar(buildStatus({
      account: { id: 'me', acct: 'alice', username: 'alice', url: 'https://example.test/alice' },
      reblog: {
        id: 'original',
        account: { id: 'other', acct: 'bob', username: 'bob', url: 'https://example.test/bob' },
        visibility: 'public',
        emoji_reactions: [],
      },
    }));

    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
  });

  it('does not show Edit on a boost of your own status', () => {
    renderBar(buildStatus({
      id: 'boost-1',
      reblog: {
        id: 'original',
        account: { id: 'me', acct: 'alice', username: 'alice', url: 'https://example.test/alice' },
        visibility: 'public',
        emoji_reactions: [],
        expires_at: null,
      },
    }));

    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Delete' })).toBeInTheDocument();
  });
});
