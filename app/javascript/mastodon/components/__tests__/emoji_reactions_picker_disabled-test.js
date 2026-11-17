/** @jest-environment jsdom */
/* eslint-disable react/prop-types */

import React from 'react';
import { fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/components/emoji', () => () => <span data-testid='emoji' />);
jest.mock('mastodon/components/animated_number', () => ({ value }) => <span>{value}</span>);
jest.mock('mastodon/components/account_popup', () => () => null);
jest.mock('mastodon/is_mobile', () => ({ isUserTouching: () => true }));
jest.mock('mastodon/initial_state', () => ({
  disableReactions: false,
  emojiPickerDisabled: true,
  me: '1',
}));

import EmojiReaction from '../emoji_reactions';
import ReactionPickerDropdown from '../reaction_picker_dropdown';

const status = fromJS({ id: 'status-1', account: 'acct-1' });
const reaction = fromJS({ name: '😀', count: 2, account_ids: ['1', '2'], domain: null, url: null, static_url: null });

function renderReaction(myReaction) {
  const store = createStore(() => fromJS({ relationships: { updateCount: 0 } }));
  const addEmojiReaction = jest.fn();
  const removeEmojiReaction = jest.fn();
  const view = render(
    <Provider store={store}>
      <EmojiReaction
        status={status}
        emojiReaction={reaction}
        myReaction={myReaction}
        addEmojiReaction={addEmojiReaction}
        removeEmojiReaction={removeEmojiReaction}
        hideAccountList
      />
    </Provider>,
  );

  return { ...view, addEmojiReaction, removeEmojiReaction };
}

describe('all emoji pickers disabled', () => {
  it('renders reaction counts but prevents adding another reaction', () => {
    const { container, addEmojiReaction } = renderReaction(false);
    const chip = container.querySelector('button.reactions-bar__item');

    expect(chip).toHaveAttribute('aria-disabled', 'true');
    expect(chip).toHaveAttribute('data-emoji-reaction-disabled', '1');
    fireEvent.click(chip);
    expect(addEmojiReaction).not.toHaveBeenCalled();
  });

  it('lets a viewer undo their previous reaction', () => {
    const { container, removeEmojiReaction } = renderReaction(true);
    const chip = container.querySelector('button.reactions-bar__item');

    expect(chip).not.toHaveAttribute('aria-disabled', 'true');
    fireEvent.click(chip);
    expect(removeEmojiReaction).toHaveBeenCalledWith(status, '😀');
  });

  it('does not render the reaction picker trigger', () => {
    const { container } = render(
      <ReactionPickerDropdown
        icon='smile-o'
        size={18}
        title='React with emoji'
        onOpen={jest.fn()}
        onClose={jest.fn()}
        onPickEmoji={jest.fn()}
        onSkinTone={jest.fn()}
        skinTone={1}
      />,
    );
    expect(container.firstChild).toBeNull();
  });
});
