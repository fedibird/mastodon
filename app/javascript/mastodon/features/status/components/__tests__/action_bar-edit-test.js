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
  enableReaction: true,
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

jest.mock('../../../../containers/dropdown_menu_container', () => ({ items, scrollable }) => (
  <div
    data-testid='more-menu'
    data-scrollable={scrollable ? 'true' : 'false'}
  >
    {(items || []).map((item, index) => item ? (
      <button key={index} type='button'>{item.text}</button>
    ) : (
      <hr key={index} data-testid='menu-separator' />
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

  it('shows Embed for a signed-in viewer of a remote public status', () => {
    renderBar(buildStatus({
      account: { id: 'other', acct: 'bob@example.com', username: 'bob', url: 'https://example.com/bob' },
    }));

    expect(screen.getByRole('button', { name: 'Embed' })).toBeInTheDocument();
  });

  it('hides Edit on a boost of your own status', () => {
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

  it('scrolls the menu and places own-status management before reaction lists', () => {
    renderBar(buildStatus({
      reblogs_count: 2,
      favourites_count: 3,
      emoji_reactions: [{ name: '👍', count: 1 }],
    }));

    expect(screen.getByTestId('more-menu')).toHaveAttribute('data-scrollable', 'true');

    const labels = screen.getAllByRole('button').map(button => button.textContent);
    const indexOf = label => labels.indexOf(label);

    expect(indexOf('Copy link to status')).toBeLessThan(indexOf('Embed'));
    expect(indexOf('Embed')).toBeLessThan(indexOf('Edit'));
    expect(indexOf('Edit')).toBeLessThan(indexOf('Delete & re-draft'));
    expect(indexOf('Delete & re-draft')).toBeLessThan(indexOf('Delete'));
    expect(indexOf('Delete')).toBeLessThan(indexOf('Expire'));
    expect(indexOf('Expire')).toBeLessThan(indexOf('Show boosted users'));
    expect(indexOf('Show boosted users')).toBeLessThan(indexOf('Show favourited users'));
    expect(indexOf('Show favourited users')).toBeLessThan(indexOf('Show emoji reactioned users'));

    const menu = screen.getByTestId('more-menu');
    const entries = Array.from(menu.children);
    expect(menu.firstElementChild).toHaveTextContent('Copy link to status');
    expect(menu.lastElementChild.tagName).not.toBe('HR');
    entries.forEach((child, index) => {
      if (child.tagName === 'HR') {
        expect(entries[index - 1].tagName).not.toBe('HR');
        expect(entries[index + 1].tagName).not.toBe('HR');
      }
    });
  });
});
