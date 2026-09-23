/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import React from 'react';
import PropTypes from 'prop-types';
import { Map as ImmutableMap, fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('../../../../initial_state', () => ({
  me: 'me',
  isStaff: false,
  show_quote_button: false,
  show_share_button: false,
  enableReaction: false,
  enableStatusReference: false,
  maxReferences: 5,
  matchVisibilityOfReferences: false,
  addReferenceModal: false,
  disablePost: false,
  disableReactions: false,
  disableBlock: false,
  disableDomainBlock: false,
  disableReport: false,
  hideListOfEmojiReactionsToPosts: false,
  hideListOfFavouritesToPosts: false,
  hideListOfReblogsToPosts: false,
  hideListOfReferredByToPosts: false,
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

jest.mock('../../../../containers/dropdown_menu_container', () => ({ items }) => (
  <div>
    {(items || []).filter(Boolean).map((item, index) => (
      <button key={index} type='button'>{item.text}</button>
    ))}
  </div>
));
jest.mock('mastodon/containers/reaction_picker_dropdown_container', () => () => null);
jest.mock('../../../../actions/filters', () => ({ initAddFilter: jest.fn() }));
jest.mock('../../../../actions/modal', () => ({ openModal: jest.fn() }));

import ActionBar from '../action_bar';

const store = createStore(() => ImmutableMap({
  relationships: ImmutableMap(),
  compose: ImmutableMap({
    references: ImmutableMap(),
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
  account: { id: 'me', acct: 'alice', username: 'alice', url: 'https://example.test/alice' },
  visibility: 'public',
  muted: false,
  reblogged: false,
  favourited: false,
  bookmarked: false,
  reblogs_count: 0,
  favourites_count: 0,
  status_referred_by_count: 0,
  emoji_reactions: [],
  expires_at: null,
  reblog: null,
  ...overrides,
});

const renderBar = status => render(
  <Provider store={store}>
    <RouterProvider>
      <ActionBar
        status={status}
        onReply={jest.fn()}
        onFavourite={jest.fn()}
        onReblog={jest.fn()}
        onQuote={jest.fn()}
        onBookmark={jest.fn()}
        onEdit={jest.fn()}
        onDelete={jest.fn()}
        onExpire={jest.fn()}
        onDirect={jest.fn()}
        onMemberList={jest.fn()}
        onMention={jest.fn()}
        addEmojiReaction={jest.fn()}
        removeEmojiReaction={jest.fn()}
      />
    </RouterProvider>
  </Provider>,
);

describe('detailed status ActionBar edit menu', () => {
  it('shows Edit for an own local status', () => {
    renderBar(buildStatus());
    expect(screen.getByRole('button', { name: 'Edit' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Delete & re-draft' })).toBeInTheDocument();
  });

  it('hides Edit for another account, an expired status, and a boost', () => {
    const { unmount } = renderBar(buildStatus({
      account: { id: 'other', acct: 'bob', username: 'bob', url: 'https://example.test/bob' },
    }));
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    unmount();

    renderBar(buildStatus({ expires_at: '2000-01-01T00:00:00.000Z' }));
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
  });
});
