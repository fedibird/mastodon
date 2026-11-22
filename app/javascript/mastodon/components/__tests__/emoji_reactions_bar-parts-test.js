import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { IntlProvider } from 'react-intl';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  reduceMotion: true,
  hideReactionCounter: false,
  hideListOfEmojiReactionsToPosts: true,
  disableReactions: false,
  emojiPickerDisabled: false,
}));

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import EmojiReactionsBar from 'mastodon/components/emoji_reactions_bar';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

const group = {
  name: 'blob',
  count: 2,
  account_ids: ['2', '1'],
  url: 'https://cdn.example/7.png',
  static_url: 'https://cdn.example/7.png',
  parts: [
    {
      identity: { kind: 'custom', scope: 'local', custom_emoji_id: '7' },
      custom_emoji_id: '7',
      account_ids: ['2'],
      url: 'https://cdn.example/7.png',
      static_url: 'https://cdn.example/7.png',
    },
    {
      identity: { kind: 'custom', scope: 'local', custom_emoji_id: '8' },
      custom_emoji_id: '8',
      account_ids: ['1'],
      url: 'https://cdn.example/8.png',
      static_url: 'https://cdn.example/8.png',
    },
  ],
};

const statusWith = reactions => fromJS({
  id: 's1',
  account: 'a1',
  emoji_reactions: reactions,
});

const reducer = (state, action) => {
  if (!state) {
    return fromJS({
      relationships: {},
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
  }

  return state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));
};

const localRule = id => ({
  id: `m-${id}`,
  revision: '2',
  emoji: { kind: 'custom', scope: 'local', custom_emoji_id: id, shortcode: 'blob' },
  replacement: '[hidden]',
  effects: { replace_in_text: false, hide_reactions: true, hide_in_picker: false, reject_reactions_to_own_posts: false },
});

const renderBar = reactions => {
  const store = createStore(reducer);
  const view = render(
    <Provider store={store}>
      <IntlProvider locale='en'>
        <EmojiReactionsBar status={statusWith(reactions)} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
      </IntlProvider>
    </Provider>,
  );

  return { ...view, store };
};

describe('EmojiReactionsBar unprojected local parts', () => {
  it('keeps the unmuted local part, its image, the count, and the viewer reaction', () => {
    const { container, store } = renderBar([group]);
    const button = () => container.querySelector('button.reactions-bar__item');

    expect(button()).not.toBeNull();
    expect(container.querySelector('img').getAttribute('src')).toBe('https://cdn.example/7.png');

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [localRule('7')],
      });
    });

    expect(container.innerHTML).not.toContain('cdn.example/7.png');
    expect(container.querySelector('img').getAttribute('src')).toBe('https://cdn.example/8.png');
    expect(container.querySelector('.reactions-bar__item__count').textContent).toBe('1');
    expect(button().className).toContain('active');

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [localRule('7'), localRule('8')],
      });
    });

    expect(container.querySelector('button.reactions-bar__item')).toBeNull();
    expect(container.innerHTML).not.toContain('cdn.example/8.png');
  });

  it('draws the surviving part when the group image is not one of those parts', () => {
    const stale = {
      name: 'house',
      count: 2,
      account_ids: ['3', '4'],
      url: 'https://cdn.example/7.png',
      static_url: 'https://cdn.example/7.png',
      parts: [
        {
          identity: { kind: 'custom', scope: 'local', custom_emoji_id: '8' },
          custom_emoji_id: '8',
          account_ids: ['3'],
          url: 'https://cdn.example/8.png',
          static_url: 'https://cdn.example/8.png',
        },
        {
          identity: { kind: 'custom', scope: 'local', custom_emoji_id: '9' },
          custom_emoji_id: '9',
          account_ids: ['4'],
          url: 'https://cdn.example/9.png',
          static_url: 'https://cdn.example/9.png',
        },
      ],
    };
    const { container, store } = renderBar([stale]);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [localRule('7')],
      });
    });

    expect(container.querySelectorAll('button.reactions-bar__item')).toHaveLength(1);
    expect(container.querySelector('img').getAttribute('src')).toBe('https://cdn.example/8.png');
    expect(container.querySelector('.reactions-bar__item__count').textContent).toBe('2');
  });

  it('keeps the chip selected when the viewer reaction is a hidden part of the same name', () => {
    const owned = {
      name: 'blob',
      count: 2,
      account_ids: ['1', '2'],
      url: 'https://cdn.example/7.png',
      static_url: 'https://cdn.example/7.png',
      parts: [
        {
          identity: { kind: 'custom', scope: 'local', custom_emoji_id: '7' },
          custom_emoji_id: '7',
          account_ids: ['1'],
          url: 'https://cdn.example/7.png',
          static_url: 'https://cdn.example/7.png',
        },
        {
          identity: { kind: 'custom', scope: 'local', custom_emoji_id: '8' },
          custom_emoji_id: '8',
          account_ids: ['2'],
          url: 'https://cdn.example/8.png',
          static_url: 'https://cdn.example/8.png',
        },
      ],
    };
    const { container, store } = renderBar([owned]);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [localRule('7')],
      });
    });

    const button = container.querySelector('button.reactions-bar__item');

    expect(container.querySelector('img').getAttribute('src')).toBe('https://cdn.example/8.png');
    expect(button.className).toContain('active');
  });
});
