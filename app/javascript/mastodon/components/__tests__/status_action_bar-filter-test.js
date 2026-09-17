/* eslint-disable react/prop-types */

import { render, fireEvent, screen } from '@testing-library/react';
import React from 'react';
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

const status = fromJS({
  id: 's1',
  account: {
    id: 'a1',
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
});

const renderBar = (props = {}) => render(
  <Provider store={store}>
    <StatusActionBar
      status={status}
      onReply={jest.fn()}
      onFavourite={jest.fn()}
      onReblog={jest.fn()}
      onQuote={jest.fn()}
      onBookmark={jest.fn()}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
      {...props}
    />
  </Provider>,
);

describe('StatusActionBar filter eye button', () => {
  it('shows the hide button before the more menu when onFilter is provided', () => {
    const onFilter = jest.fn();
    renderBar({ onFilter });

    const hideButton = screen.getByTitle('Hide post');
    expect(hideButton).toBeInTheDocument();
    expect(hideButton.compareDocumentPosition(screen.getByTestId('more-menu'))).toEqual(
      Node.DOCUMENT_POSITION_FOLLOWING,
    );

    fireEvent.click(hideButton);
    expect(onFilter).toHaveBeenCalledTimes(1);
  });

  it('does not show the hide button on ordinary statuses', () => {
    renderBar();

    expect(screen.queryByTitle('Hide post')).not.toBeInTheDocument();
    expect(screen.getByTitle('Quote')).toBeInTheDocument();
    expect(screen.getByTitle('Reference')).toBeInTheDocument();
    expect(screen.getByTitle('Bookmark')).toBeInTheDocument();
    expect(screen.getByTestId('emoji-reaction')).toBeInTheDocument();
    expect(screen.getByTestId('more-menu')).toBeInTheDocument();
  });
});

describe('StatusActionBar Filter this post menu', () => {
  it('shows Filter this post in the more menu when onAddFilter is provided', () => {
    const onAddFilter = jest.fn();
    renderBar({ onAddFilter });

    fireEvent.click(screen.getByText('Filter this post'));
    expect(onAddFilter).toHaveBeenCalledTimes(1);
    expect(onAddFilter.mock.calls[0][0].get('id')).toEqual('s1');
  });

  it('does not add Filter this post when onAddFilter is missing', () => {
    renderBar();

    expect(screen.queryByText('Filter this post')).not.toBeInTheDocument();
  });

  it('does not add Filter this post for expired statuses', () => {
    renderBar({ onAddFilter: jest.fn(), expired: true });

    expect(screen.queryByText('Filter this post')).not.toBeInTheDocument();
  });

  it('keeps the hide eye button distinct from Filter this post', () => {
    const onFilter = jest.fn();
    const onAddFilter = jest.fn();
    renderBar({ onFilter, onAddFilter });

    expect(screen.getByTitle('Hide post')).toBeInTheDocument();
    expect(screen.getByText('Filter this post')).toBeInTheDocument();

    fireEvent.click(screen.getByTitle('Hide post'));
    expect(onFilter).toHaveBeenCalledTimes(1);
    expect(onAddFilter).not.toHaveBeenCalled();
  });
});
