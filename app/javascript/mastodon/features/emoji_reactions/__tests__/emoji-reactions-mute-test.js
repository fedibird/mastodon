/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  defaultColumnWidth: 'normal',
  autoPlayEmoji: false,
}));

jest.mock('react-intl', () => {
  const intl = { formatMessage: ({ defaultMessage }) => defaultMessage };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => <span>{defaultMessage}</span>,
  };
});

jest.mock('mastodon/containers/account_container', () => ({ id, append }) => (
  <div data-testid={`account-${id}`}>{append}</div>
));
jest.mock('mastodon/features/ui/components/column', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/components/column_header', () => () => <div data-testid='column-header' />);
jest.mock('mastodon/components/scrollable_list', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/features/reactioned/containers/header_container', () => () => null);

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import Emoji from 'mastodon/components/emoji';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import EmojiReactions from '../index';

const mutedRule = {
  id: 'm1',
  revision: '3',
  emoji: { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' },
  replacement: '[blob]',
  effects: {
    replace_in_text: true,
    hide_reactions: true,
    hide_in_picker: true,
    reject_reactions_to_own_posts: true,
  },
};

const reactions = [
  { account: '1', name: 'blob', url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png', domain: 'remote.example' },
  { account: '2', name: 'star', url: 'https://cdn.example/keep.svg', static_url: 'https://cdn.example/keep.png', domain: 'other.example' },
];

const initial = fromJS({
  settings: { columns: [], emoji_reactioned_by: {} },
  user_lists: {
    emoji_reactioned_by: {
      s1: { items: reactions, isLoading: false, next: null },
    },
  },
  emojiMutes: {
    revision: '1',
    appliedRevision: '1',
    phase: 'ready',
    failure: null,
    rules: [],
    availability: 'enabled',
    display: 'apply',
  },
});

const reducer = (state = initial, action) => {
  if (action.type === 'SHOW_KEEP_RULES') {
    return state
      .setIn(['emojiMutes', 'display'], 'show')
      .setIn(['emojiMutes', 'rules'], fromJS(action.rules || []));
  }

  return state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));
};

const renderList = store => render(
  <Provider store={store}>
    <div className='emoji-mutes-privacy-portal'>
      <EmojiReactions params={{ statusId: 's1' }} />
    </div>
  </Provider>,
);

describe('emoji reaction overview mute state', () => {
  it('suppresses an open list, a list opened while unverified, and restores only unmuted emoji', () => {
    const store = createStore(reducer);
    const open = renderList(store);

    expect(open.container.querySelector('img[src="https://cdn.example/blob.png"]')).not.toBeNull();
    expect(open.container.querySelector('img[src="https://cdn.example/keep.png"]')).not.toBeNull();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });

    expect(open.container.querySelector('img')).toBeNull();
    expect(open.container.querySelectorAll('.emoji-mute-unverified').length).toBeGreaterThan(0);
    expect(open.container.innerHTML).not.toContain('cdn.example');

    open.unmount();

    const during = renderList(store);
    expect(during.container.querySelector('img')).toBeNull();
    expect(during.container.innerHTML).not.toContain('cdn.example');
    during.unmount();

    const again = renderList(store);
    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [mutedRule],
      });
    });

    expect(again.container.querySelector('img[src="https://cdn.example/blob.png"]')).toBeNull();
    expect(again.container.querySelector('img[src="https://cdn.example/keep.png"]')).not.toBeNull();
    expect(again.container.querySelector('img[src="https://cdn.example/keep.png"]').hasAttribute('hidden')).toBe(false);
    expect(() => again.unmount()).not.toThrow();
  });

  it('restores an overview glyph by hide_reactions across the same act and a later act', () => {
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);
    let beforeCommit = null;
    const textOnly = {
      ...mutedRule,
      effects: { ...mutedRule.effects, replace_in_text: true, hide_reactions: false },
    };

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'display']) !== 'apply' || store.getState().getIn(['emojiMutes', 'revision']) !== '3') {
        return;
      }

      const blob = document.querySelector('[data-emoji-reaction-name="blob"] img');
      const star = document.querySelector('[data-emoji-reaction-name="star"] img');

      beforeCommit = {
        blobSrc: blob && blob.getAttribute('src'),
        blobHidden: blob && blob.hasAttribute('hidden'),
        starSrc: star && star.getAttribute('src'),
      };
    });

    const view = renderList(store);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [textOnly],
      });
    });

    expect(beforeCommit.blobSrc).toBe('https://cdn.example/blob.png');
    expect(beforeCommit.blobHidden).toBe(false);
    expect(beforeCommit.starSrc).toBe('https://cdn.example/keep.png');
    expect(view.container.querySelector('[data-emoji-reaction-name="blob"] img').getAttribute('src')).toBe('https://cdn.example/blob.png');
    expect(view.container.querySelector('[data-emoji-reaction-domain="remote.example"]')).not.toBeNull();

    let hiddenBeforeCommit = null;

    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'revision']) !== '5') {
        return;
      }

      const blob = document.querySelector('[data-emoji-reaction-name="blob"] img');

      hiddenBeforeCommit = blob && blob.getAttribute('src');
    });

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '4' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '5',
        availability: 'enabled',
        mutes: [mutedRule],
      });
    });

    expect(hiddenBeforeCommit).toBeNull();
    expect(view.container.querySelector('[data-emoji-reaction-name="star"] img').getAttribute('src')).toBe('https://cdn.example/keep.png');
    view.unmount();
  });

  it('restores a hidden overview glyph when display becomes show with the old rule still stored', () => {
    const guard = createUnverifiedEmojiGuard();
    const store = createStore(reducer);

    store.subscribe(() => guard(store.getState()));
    const view = renderList(store);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
      store.dispatch({ type: 'SHOW_KEEP_RULES', rules: [mutedRule] });
    });

    const blob = view.container.querySelector('[data-emoji-reaction-name="blob"] img');

    expect(blob).not.toBeNull();
    expect(blob.getAttribute('src')).toBe('https://cdn.example/blob.png');
    expect(blob.hasAttribute('hidden')).toBe(false);
    expect(blob.getAttribute('alt') || view.container.innerHTML).not.toContain('[blob]');
    view.unmount();
  });

  it('restores a directly rendered emoji after unverified concealment', () => {
    const store = createStore(reducer);
    const view = render(
      <Provider store={store}>
        <Emoji emoji='blob' hovered={false} url='https://cdn.example/blob.svg' static_url='https://cdn.example/blob.png' />
      </Provider>,
    );

    expect(view.container.querySelector('img').getAttribute('src')).toBe('https://cdn.example/blob.png');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '2' });
    });
    expect(view.container.querySelector('img')).toBeNull();

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [],
      });
    });

    expect(view.container.querySelector('img').getAttribute('src')).toBe('https://cdn.example/blob.png');
    expect(view.container.querySelector('img').hasAttribute('hidden')).toBe(false);
    view.unmount();
  });
});
