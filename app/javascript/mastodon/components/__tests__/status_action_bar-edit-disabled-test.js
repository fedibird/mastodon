/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
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
  enableReaction: false,
  compactReaction: false,
  enableStatusReference: false,
  maxReferences: 5,
  matchVisibilityOfReferences: false,
  addReferenceModal: false,
  disablePost: true,
  disableReactions: false,
  disableBlock: false,
  disableDomainBlock: false,
  disableReport: false,
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
    now: () => Date.now(),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../../containers/dropdown_menu_container', () => ({ items }) => (
  <div>
    {(items || []).filter(Boolean).map((item, index) => (
      <button key={index} type='button'>{item.text}</button>
    ))}
  </div>
));
jest.mock('../../containers/reaction_picker_dropdown_container', () => () => null);

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
  account: { id: 'me', acct: 'alice', username: 'alice', url: 'https://example.test/alice' },
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
  emoji_reactions: [],
  url: 'https://example.test/s1',
});

describe('StatusActionBar edit menu when posting is disabled', () => {
  it('does not show Edit', () => {
    render(
      <Provider store={store}>
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
        />
      </Provider>,
    );

    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Delete' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Delete & re-draft' })).not.toBeInTheDocument();
  });
});
