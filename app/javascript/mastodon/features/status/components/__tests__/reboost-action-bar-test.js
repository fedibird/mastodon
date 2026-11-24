/* eslint-disable react/prop-types */

import { act, fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import PropTypes from 'prop-types';
import { Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('../../../../initial_state', () => ({
  me: 'me',
  isStaff: false,
  show_quote_button: true,
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
  hideListOfEmojiReactionsToPosts: true,
  hideListOfFavouritesToPosts: true,
  hideListOfReblogsToPosts: true,
  hideListOfReferredByToPosts: true,
  enableReboost: true,
}));

jest.mock('../../../../is_mobile', () => ({
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

jest.mock('mastodon/containers/reaction_picker_dropdown_container', () => () => null);

import statuses from '../../../../reducers/statuses';
import { REBOOST_OPERATION } from '../../../../actions/interactions';
import ActionBar from '../action_bar';

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
    next = next.setIn(['dropdown_menu', 'openId'], action.id);
  } else if (action.type === 'DROPDOWN_MENU_CLOSE') {
    next = next.setIn(['dropdown_menu', 'openId'], null);
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

describe('detailed status reboost menu', () => {
  it('opens boost actions and disables reboost while an operation is open', () => {
    const store = createStore(root, applyMiddleware(thunk));
    const onReboost = jest.fn();
    const onReblog = jest.fn();
    const status = fromJS({
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
      emoji_reactions: [],
      url: 'https://example.test/s1',
    });

    render(
      <Provider store={store}>
        <RouterProvider>
          <ActionBar
            status={status}
            onReply={jest.fn()}
            onFavourite={jest.fn()}
            onReblog={onReblog}
            onReboost={onReboost}
            onUnreblog={jest.fn()}
            onQuote={jest.fn()}
            onBookmark={jest.fn()}
            onDelete={jest.fn()}
            onExpire={jest.fn()}
            onDirect={jest.fn()}
            onMemberList={jest.fn()}
            onMention={jest.fn()}
            onMute={jest.fn()}
            onBlock={jest.fn()}
            onReport={jest.fn()}
            onEmbed={jest.fn()}
            onMuteConversation={jest.fn()}
            onPin={jest.fn()}
            addEmojiReaction={jest.fn()}
            removeEmojiReaction={jest.fn()}
          />
        </RouterProvider>
      </Provider>,
    );

    const trigger = screen.getByRole('button', { name: 'Boost actions' });
    expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
    expect(trigger).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(trigger);
    expect(trigger).toHaveAttribute('aria-expanded', 'true');
    fireEvent.click(screen.getByRole('button', { name: 'Reboost' }));
    expect(onReboost).toHaveBeenCalledTimes(1);
    expect(onReblog).not.toHaveBeenCalled();

    act(() => {
      store.dispatch({ type: REBOOST_OPERATION, statusId: 's1', operation: { id: '9', state: 'federating' } });
    });
    fireEvent.click(screen.getByRole('button', { name: 'Boost actions' }));
    expect(screen.getByRole('button', { name: 'Reboost' })).toHaveAttribute('aria-disabled', 'true');
  });

  it('shows the cooldown when the detail status includes reboost_retry_after', () => {
    const store = createStore(root, applyMiddleware(thunk));
    const status = fromJS({
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
      emoji_reactions: [],
      reboost_retry_after: 240,
      url: 'https://example.test/s1',
    });

    render(
      <Provider store={store}>
        <RouterProvider>
          <ActionBar
            status={status}
            onReply={jest.fn()}
            onFavourite={jest.fn()}
            onReblog={jest.fn()}
            onReboost={jest.fn()}
            onUnreblog={jest.fn()}
            onQuote={jest.fn()}
            onBookmark={jest.fn()}
            onDelete={jest.fn()}
            onExpire={jest.fn()}
            onDirect={jest.fn()}
            onMemberList={jest.fn()}
            onMention={jest.fn()}
            onMute={jest.fn()}
            onBlock={jest.fn()}
            onReport={jest.fn()}
            onEmbed={jest.fn()}
            onMuteConversation={jest.fn()}
            onPin={jest.fn()}
            addEmojiReaction={jest.fn()}
            removeEmojiReaction={jest.fn()}
          />
        </RouterProvider>
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Boost actions' }));
    expect(screen.getByRole('button', { name: 'Reboost (about 4 min left)' })).toHaveAttribute('aria-disabled', 'true');
  });

  it('disables a new boost on the detail view while the cooldown is running', () => {
    const store = createStore(root, applyMiddleware(thunk));
    const status = fromJS({
      id: 's1',
      account: { id: 'other', acct: 'bob', username: 'bob', url: 'https://example.test/bob' },
      visibility: 'public',
      muted: false,
      reblogged: false,
      favourited: false,
      bookmarked: false,
      reblogs_count: 1,
      favourites_count: 0,
      replies_count: 0,
      status_referred_by_count: 0,
      emoji_reactions: [],
      reboost_retry_after: 240,
      url: 'https://example.test/s1',
    });

    render(
      <Provider store={store}>
        <RouterProvider>
          <ActionBar
            status={status}
            onReply={jest.fn()}
            onFavourite={jest.fn()}
            onReblog={jest.fn()}
            onReboost={jest.fn()}
            onUnreblog={jest.fn()}
            onQuote={jest.fn()}
            onBookmark={jest.fn()}
            onDelete={jest.fn()}
            onExpire={jest.fn()}
            onDirect={jest.fn()}
            onMemberList={jest.fn()}
            onMention={jest.fn()}
            onMute={jest.fn()}
            onBlock={jest.fn()}
            onReport={jest.fn()}
            onEmbed={jest.fn()}
            onMuteConversation={jest.fn()}
            onPin={jest.fn()}
            addEmojiReaction={jest.fn()}
            removeEmojiReaction={jest.fn()}
          />
        </RouterProvider>
      </Provider>,
    );

    expect(screen.getByRole('button', { name: 'Reboost (about 4 min left)' })).toBeDisabled();
  });

  it('enables a new boost when the cooldown deadline passes', () => {
    jest.useFakeTimers('modern');
    jest.setSystemTime(new Date('2026-11-24T00:00:00Z'));
    const store = createStore(root, applyMiddleware(thunk));
    const status = fromJS({
      id: 's1',
      account: { id: 'other', acct: 'bob', username: 'bob', url: 'https://example.test/bob' },
      visibility: 'public',
      muted: false,
      reblogged: false,
      favourited: false,
      bookmarked: false,
      reblogs_count: 1,
      favourites_count: 0,
      replies_count: 0,
      status_referred_by_count: 0,
      emoji_reactions: [],
      reboost_retry_until: Date.now() + 5000,
      url: 'https://example.test/s1',
    });

    render(
      <Provider store={store}>
        <RouterProvider>
          <ActionBar
            status={status}
            onReply={jest.fn()}
            onFavourite={jest.fn()}
            onReblog={jest.fn()}
            onReboost={jest.fn()}
            onUnreblog={jest.fn()}
            onQuote={jest.fn()}
            onBookmark={jest.fn()}
            onDelete={jest.fn()}
            onExpire={jest.fn()}
            onDirect={jest.fn()}
            onMemberList={jest.fn()}
            onMention={jest.fn()}
            onMute={jest.fn()}
            onBlock={jest.fn()}
            onReport={jest.fn()}
            onEmbed={jest.fn()}
            onMuteConversation={jest.fn()}
            onPin={jest.fn()}
            addEmojiReaction={jest.fn()}
            removeEmojiReaction={jest.fn()}
          />
        </RouterProvider>
      </Provider>,
    );

    expect(screen.getByRole('button', { name: 'Reboost (about 1 min left)' })).toBeDisabled();
    act(() => {
      jest.advanceTimersByTime(5000);
    });
    expect(screen.getByRole('button', { name: 'Boost' })).toBeEnabled();
    jest.useRealTimers();
  });
});
