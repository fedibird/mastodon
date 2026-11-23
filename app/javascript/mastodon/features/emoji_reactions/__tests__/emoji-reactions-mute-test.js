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

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_ENABLE, EMOJI_MUTES_IGNORE, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
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
    expect(open.container.innerHTML).not.toContain('data-emoji-');
    expect(open.container.innerHTML).not.toContain('blob');
    expect(open.container.innerHTML).not.toContain('remote.example');

    open.unmount();

    const during = renderList(store);
    expect(during.container.querySelector('img')).toBeNull();
    expect(during.container.innerHTML).not.toContain('cdn.example');
    expect(during.container.innerHTML).not.toContain('data-emoji-');
    expect(during.container.outerHTML).not.toContain('blob');
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

    const blobImage = view.container.querySelector('[data-emoji-reaction-name="blob"] img');
    const blobHost = blobImage.closest('.account__emoji_reaction');
    let hiddenBeforeCommit = null;

    store.subscribe(() => {
      if (store.getState().getIn(['emojiMutes', 'revision']) !== '5') {
        return;
      }

      hiddenBeforeCommit = {
        src: blobImage.getAttribute('src'),
        hidden: blobImage.hasAttribute('hidden'),
        ariaHidden: blobImage.getAttribute('aria-hidden'),
        hostName: blobHost.getAttribute('data-emoji-reaction-name'),
        hostDomain: blobHost.getAttribute('data-emoji-reaction-domain'),
        hostId: blobHost.getAttribute('data-emoji-custom-emoji-id'),
        hostNative: blobHost.getAttribute('data-emoji-native'),
        shortcode: blobImage.getAttribute('data-shortcode'),
        domain: blobImage.getAttribute('data-domain'),
      };
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

    expect(hiddenBeforeCommit.src).toBeNull();
    expect(hiddenBeforeCommit.hidden).toBe(true);
    expect(hiddenBeforeCommit.ariaHidden).toBe('true');
    expect(hiddenBeforeCommit.hostName).toBeNull();
    expect(hiddenBeforeCommit.hostDomain).toBeNull();
    expect(hiddenBeforeCommit.hostId).toBeNull();
    expect(hiddenBeforeCommit.hostNative).toBeNull();
    expect(hiddenBeforeCommit.shortcode).toBeNull();
    expect(hiddenBeforeCommit.domain).toBeNull();
    expect(blobImage.getAttribute('src')).toBeNull();
    expect(view.container.innerHTML).not.toContain('https://cdn.example/blob.png');
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

  it('keeps raw reaction identity out of a list first mounted while suppressed', () => {
    const native = '👌';
    const items = [
      { account: '1', name: 'blob', url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png', domain: 'remote.example' },
      { account: '2', name: 'house', url: 'https://cdn.example/house.svg', static_url: 'https://cdn.example/house.png', custom_emoji_id: '42' },
      { account: '3', name: native },
    ];
    const hide = (on) => ({
      replace_in_text: false,
      hide_reactions: on,
      hide_in_picker: false,
      reject_reactions_to_own_posts: false,
    });
    const hiddenRules = [
      mutedRule,
      { id: 'm-local', revision: '4', emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '42', shortcode: 'house' }, replacement: '[house]', effects: hide(true) },
      { id: 'm-unicode', revision: '4', emoji: { kind: 'unicode', native }, replacement: '[up]', effects: hide(true) },
    ];
    const shownRules = hiddenRules.map(rule => ({ ...rule, effects: hide(false) }));
    const concealed = (container) => {
      const html = container.outerHTML;

      expect(html).not.toContain('blob');
      expect(html).not.toContain('remote.example');
      expect(html).not.toContain('house');
      expect(html).not.toContain('42');
      expect(html).not.toContain(native);
      expect(html).not.toContain('data-emoji-');
      expect(html).not.toContain('cdn.example');
      expect(container.querySelector('.account__emoji_reaction [title], .account__emoji_reaction [alt], .account__emoji_reaction [aria-label]')).toBeNull();
      expect(container.textContent).toContain('\u25FB');
    };

    const store = createStore(reducer, initial
      .setIn(['user_lists', 'emoji_reactioned_by', 's1', 'items'], fromJS(items))
      .setIn(['emojiMutes', 'display'], 'suppress'));
    const first = renderList(store);

    concealed(first.container);
    first.unmount();

    const openedLater = renderList(store);

    concealed(openedLater.container);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: hiddenRules,
      });
    });

    expect(openedLater.container.outerHTML).not.toContain('blob');
    expect(openedLater.container.outerHTML).not.toContain('remote.example');
    expect(openedLater.container.outerHTML).not.toContain('house');
    expect(openedLater.container.outerHTML).not.toContain('42');
    expect(openedLater.container.outerHTML).not.toContain(native);
    expect(openedLater.container.outerHTML).not.toContain('data-emoji-');

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '5',
        availability: 'enabled',
        mutes: shownRules,
      });
    });

    expect(openedLater.container.querySelector('[data-emoji-reaction-domain="remote.example"]').getAttribute('data-emoji-reaction-name')).toBe('blob');
    expect(openedLater.container.querySelector('[data-emoji-custom-emoji-id="42"]').getAttribute('data-emoji-reaction-name')).toBe('house');
    expect(openedLater.container.querySelector(`[data-emoji-native="${native}"]`)).not.toBeNull();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '6' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '7',
        availability: 'enabled',
        mutes: hiddenRules,
      });
    });

    expect(openedLater.container.outerHTML).not.toContain('data-emoji-');
    expect(openedLater.container.outerHTML).not.toContain('remote.example');
    expect(openedLater.container.outerHTML).not.toContain(native);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(openedLater.container.querySelector('[data-emoji-reaction-name="blob"] img')).not.toBeNull();
    expect(openedLater.container.querySelector('[data-emoji-custom-emoji-id="42"]')).not.toBeNull();
    expect(openedLater.container.querySelector(`[data-emoji-native="${native}"]`)).not.toBeNull();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_ENABLE });
    });

    expect(openedLater.container.querySelector('[data-emoji-reaction-name="blob"] img')).toBeNull();
    expect(openedLater.container.querySelector(`[data-emoji-native="${native}"]`)).toBeNull();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(openedLater.container.querySelector('[data-emoji-reaction-name="blob"] img')).not.toBeNull();
    expect(openedLater.container.querySelector('[data-emoji-native]')).not.toBeNull();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '8' });
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '9',
        availability: 'enabled',
        mutes: hiddenRules,
      });
    });

    expect(openedLater.container.outerHTML).not.toContain('data-emoji-');
    expect(openedLater.container.outerHTML).not.toContain('remote.example');
    expect(openedLater.container.outerHTML).not.toContain(native);
    openedLater.unmount();
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
