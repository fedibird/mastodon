/**
 * @jest-environment jsdom
 */
/* eslint-disable react/prop-types */

import React from 'react';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { LONG_PRESS_MS } from 'mastodon/features/emoji/long_press';
import {
  openEmojiActions,
  resetEmojiActionsBusForTests,
  setEmojiActionsListener,
} from 'mastodon/features/emoji/emoji_actions/bus';

jest.mock('mastodon/components/emoji', () => () => <span data-testid='emoji' />);
jest.mock('mastodon/components/animated_number', () => ({ value }) => <span>{value}</span>);
jest.mock('mastodon/components/account_popup', () => () => null);
jest.mock('mastodon/is_mobile', () => ({ isUserTouching: () => true }));
jest.mock('mastodon/initial_state', () => ({ disableReactions: false, me: '1' }));

import EmojiReaction from '../emoji_reactions';

const status = fromJS({
  id: 'status-1',
  account: 'acct-1',
});

const reaction = fromJS({
  name: '😀',
  count: 2,
  account_ids: ['1', '2'],
  url: null,
  static_url: null,
  domain: null,
});

function renderChip(props = {}) {
  const store = createStore(() => fromJS({
    relationships: { updateCount: 0 },
  }));

  const addEmojiReaction = jest.fn();
  const removeEmojiReaction = jest.fn();

  const view = render(
    <Provider store={store}>
      <EmojiReaction
        status={status}
        emojiReaction={reaction}
        myReaction={false}
        addEmojiReaction={addEmojiReaction}
        removeEmojiReaction={removeEmojiReaction}
        reactionLimitReached={false}
        hideAccountList
        {...props}
      />
    </Provider>,
  );

  return { ...view, addEmojiReaction, removeEmojiReaction };
}

describe('EmojiReaction manage entry without ⋯', () => {
  beforeEach(() => {
    resetEmojiActionsBusForTests();
  });

  afterEach(() => {
    cleanup();
    resetEmojiActionsBusForTests();
    jest.useRealTimers();
  });

  const chipButton = () => document.querySelector('button.reactions-bar__item');

  it('does not render a manage ⋯ control', () => {
    renderChip();

    expect(document.querySelector('.reactions-bar__item-actions')).toBeNull();
    expect(screen.queryByLabelText(/emoji actions/i)).toBeNull();
    expect(screen.queryByText('⋯')).toBeNull();
  });

  it('keeps normal click as add reaction', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    const { addEmojiReaction } = renderChip();

    fireEvent.click(chipButton());

    expect(addEmojiReaction).toHaveBeenCalledTimes(1);
    expect(listener).not.toHaveBeenCalled();
  });

  it('opens the shared menu from contextmenu without reacting', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    const { addEmojiReaction } = renderChip();
    const chip = chipButton();

    fireEvent.contextMenu(chip);

    expect(addEmojiReaction).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledWith(expect.objectContaining({
      source: 'reaction',
      status_id: 'status-1',
      account_id: 'acct-1',
      reaction: expect.objectContaining({
        name: '😀',
        my_reaction: false,
      }),
    }));
  });

  it('opens the shared menu from long-press and suppresses the following click', () => {
    jest.useFakeTimers();
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    const { addEmojiReaction } = renderChip();
    const chip = chipButton();
    const touch = { identifier: 3, clientX: 2, clientY: 2 };

    fireEvent.touchStart(chip, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    fireEvent.touchEnd(chip, { changedTouches: [touch] });
    fireEvent.click(chip, { detail: 1 });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener.mock.calls[0][0].source).toBe('reaction');
    expect(addEmojiReaction).not.toHaveBeenCalled();
  });

  it('does not react after a multi-second mouse long-press when click follows pointerup', () => {
    jest.useFakeTimers();
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    const { addEmojiReaction, removeEmojiReaction } = renderChip();
    const chip = chipButton();

    fireEvent.pointerDown(chip, { button: 0, pointerId: 1, pointerType: 'mouse', clientX: 0, clientY: 0 });
    act(() => {
      jest.advanceTimersByTime(2000);
    });
    fireEvent.pointerUp(chip, { button: 0, pointerId: 1, pointerType: 'mouse', clientX: 0, clientY: 0 });
    fireEvent.click(chip, { detail: 1 });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener.mock.calls[0][0].source).toBe('reaction');
    expect(addEmojiReaction).not.toHaveBeenCalled();
    expect(removeEmojiReaction).not.toHaveBeenCalled();
  });

  it('does not react after a multi-second touch long-press ending non-cancelable', () => {
    jest.useFakeTimers();
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    const { addEmojiReaction } = renderChip();
    const chip = chipButton();
    const touch = { identifier: 9, clientX: 4, clientY: 4 };

    fireEvent.touchStart(chip, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(2000);
    });

    const touchEnd = new Event('touchend', { bubbles: true, cancelable: false });
    Object.defineProperty(touchEnd, 'changedTouches', { value: [touch] });
    Object.defineProperty(touchEnd, 'touches', { value: [] });
    chip.dispatchEvent(touchEnd);
    fireEvent.click(chip, { detail: 1 });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(addEmojiReaction).not.toHaveBeenCalled();

    fireEvent.click(chip, { detail: 1 });
    expect(addEmojiReaction).toHaveBeenCalledTimes(1);
  });

  it('still opens the menu when the reaction limit is reached', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    const { addEmojiReaction } = renderChip({ reactionLimitReached: true });
    const chip = chipButton();

    fireEvent.contextMenu(chip);
    fireEvent.click(chip);

    expect(listener).toHaveBeenCalledTimes(1);
    expect(addEmojiReaction).not.toHaveBeenCalled();
    expect(chip).toHaveAttribute('aria-disabled', 'true');
  });

  it('keeps reaction dataset so document Shift+F10 / contextmenu can reopen with reaction source', () => {
    const listener = jest.fn();
    setEmojiActionsListener(listener);
    renderChip({ myReaction: true });
    const chip = chipButton();

    expect(chip.getAttribute('data-emoji-actions')).toBe('1');
    expect(chip.getAttribute('data-emoji-source')).toBe('reaction');
    expect(chip.getAttribute('data-emoji-my-reaction')).toBe('1');

    expect(openEmojiActions(
      { kind: 'unicode', native: '😀' },
      {
        anchor: chip,
        status_id: chip.getAttribute('data-emoji-status-id'),
        account_id: chip.getAttribute('data-emoji-account-id'),
        source: chip.getAttribute('data-emoji-source'),
        reaction: {
          name: chip.getAttribute('data-emoji-reaction-name'),
          my_reaction: chip.getAttribute('data-emoji-my-reaction') === '1',
        },
      },
    )).toBe(true);

    expect(listener).toHaveBeenCalledWith(expect.objectContaining({
      source: 'reaction',
      reaction: expect.objectContaining({ name: '😀', my_reaction: true }),
    }));
  });
});
