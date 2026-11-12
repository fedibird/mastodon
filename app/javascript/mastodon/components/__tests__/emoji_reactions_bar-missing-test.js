import { render } from '@testing-library/react';
import React from 'react';
import { fromJS, Map as ImmutableMap } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('../../initial_state', () => ({
  me: 'me',
  reduceMotion: true,
  hideReactionCounter: false,
  hideListOfEmojiReactionsToPosts: false,
}));

jest.mock('../../utils/appearance_preferences', () => ({
  reduceMotionNow: () => true,
  watchReduceMotion: () => jest.fn(),
}));

import EmojiReactionsBar from '../emoji_reactions_bar';

const store = createStore(() => ImmutableMap());

const renderBar = status => render(
  <Provider store={store}>
    <EmojiReactionsBar
      status={status}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
    />
  </Provider>,
);

describe('EmojiReactionsBar with temporarily withheld emoji reactions', () => {
  it('does not fail to render when emoji_reactions is absent', () => {
    const { container } = renderBar(fromJS({ id: 's1' }));

    expect(container.querySelector('.emoji-reactions-bar')).toBeNull();
  });

  it('does not fail to render when emoji_reactions is explicitly undefined', () => {
    const { container } = renderBar(fromJS({ id: 's1', emoji_reactions: undefined }));

    expect(container.querySelector('.emoji-reactions-bar')).toBeNull();
  });

  it('does not fail to render when emoji_reactions is null', () => {
    const { container } = renderBar(fromJS({ id: 's1', emoji_reactions: null }));

    expect(container.querySelector('.emoji-reactions-bar')).toBeNull();
  });
});
