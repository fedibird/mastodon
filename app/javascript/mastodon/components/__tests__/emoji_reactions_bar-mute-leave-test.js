/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  reduceMotion: false,
  hideReactionCounter: true,
  hideListOfEmojiReactionsToPosts: true,
  disableReactions: false,
  emojiPickerDisabled: false,
}));

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import EmojiReactionsBar from 'mastodon/components/emoji_reactions_bar';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

const status = fromJS({
  id: 's1',
  account: 'a1',
  emoji_reactions: [
    { name: 'blob', count: 1, account_ids: ['2'], domain: 'remote.example', url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png' },
    { name: 'star', count: 1, account_ids: ['2'], domain: 'other.example', url: 'https://cdn.example/star.svg', static_url: 'https://cdn.example/star.png' },
  ],
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

  if (action.type === 'UNRELATED') {
    return state;
  }

  return state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));
};

describe('EmojiReactionsBar rule updates', () => {
  it('does not draw a rule-hidden reaction while it would be leaving', () => {
    const store = createStore(reducer);
    const view = render(
      <Provider store={store}>
        <EmojiReactionsBar status={status} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
      </Provider>,
    );

    expect(view.container.querySelector('button[title=":blob:"]')).not.toBeNull();
    expect(view.container.querySelector('button[title=":star:"]')).not.toBeNull();

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [{
          id: 'm-blob',
          revision: '2',
          emoji: { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' },
          replacement: '[blob]',
          effects: { replace_in_text: true, hide_reactions: true, hide_in_picker: true, reject_reactions_to_own_posts: true },
        }],
      });
    });

    expect(view.container.querySelector('button[title=":blob:"]')).toBeNull();
    expect(view.container.innerHTML).not.toContain('cdn.example/blob');
    expect(view.container.querySelector('button[title=":star:"]')).not.toBeNull();
    expect(view.container.querySelector('img[src="https://cdn.example/star.png"]')).not.toBeNull();

    act(() => {
      store.dispatch({ type: 'UNRELATED' });
    });

    expect(view.container.querySelector('button[title=":star:"]')).not.toBeNull();
    expect(() => view.unmount()).not.toThrow();
  });

  it('keeps an ordinary removal in the leave animation', () => {
    const store = createStore(reducer);
    const view = render(
      <Provider store={store}>
        <EmojiReactionsBar status={status} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
      </Provider>,
    );
    const fewer = status.set('emoji_reactions', status.get('emoji_reactions').filter(reaction => reaction.get('name') !== 'star'));

    view.rerender(
      <Provider store={store}>
        <EmojiReactionsBar status={fewer} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
      </Provider>,
    );

    expect(view.container.querySelector('button[title=":blob:"]')).not.toBeNull();
    expect(view.container.querySelector('button[title=":star:"]')).not.toBeNull();
    view.unmount();
  });
});
