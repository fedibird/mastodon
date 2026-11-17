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
  enableReaction: false,
  compactReaction: false,
  enableStatusReference: false,
  maxReferences: 5,
  matchVisibilityOfReferences: false,
  addReferenceModal: false,
  disablePost: false,
  disableReactions: false,
  disableBlock: false,
  disableDomainBlock: false,
  disableReport: false,
  enableReboost: false,
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
  <div>{(items || []).map((item, index) => item ? <button key={index} type='button'>{item.text}</button> : null)}</div>
));
jest.mock('../../containers/reaction_picker_dropdown_container', () => () => null);

import StatusActionBar from '../status_action_bar';

const store = createStore(() => ImmutableMap({
  relationships: ImmutableMap(),
  compose: ImmutableMap({ references: ImmutableSet(), privacy: 'public' }),
  statuses: ImmutableMap(),
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

describe('StatusActionBar without reboost', () => {
  it('keeps the unreblog button when the feature is off', () => {
    render(
      <Provider store={store}>
        <RouterProvider>
          <StatusActionBar
            status={fromJS({
              id: 's1',
              account: { id: 'other', acct: 'bob', username: 'bob', url: 'https://example.test/bob' },
              visibility: 'public',
              reblogged: true,
              favourited: false,
              bookmarked: false,
              reblogs_count: 1,
              favourites_count: 0,
              replies_count: 0,
              status_referred_by_count: 0,
              emoji_reactions: [],
              url: 'https://example.test/s1',
            })}
            onReply={jest.fn()}
            onFavourite={jest.fn()}
            onReblog={jest.fn()}
            onQuote={jest.fn()}
            onBookmark={jest.fn()}
          />
        </RouterProvider>
      </Provider>,
    );

    expect(screen.getByRole('button', { name: 'Unboost' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Boost actions' })).not.toBeInTheDocument();
  });
});
