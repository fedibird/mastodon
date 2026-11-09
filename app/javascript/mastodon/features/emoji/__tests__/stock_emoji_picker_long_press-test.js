/**
 * @jest-environment jsdom
 */

import React from 'react';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { LONG_PRESS_MS } from '../long_press';
import { openEmojiActions } from '../emoji_actions/bus';
import StockEmojiPicker from '../stock_emoji_picker';

jest.mock('react-intl', () => {
  const intl = { formatMessage: descriptor => descriptor.defaultMessage };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

jest.mock('../emoji_actions/bus', () => ({
  openEmojiActions: jest.fn(() => true),
}));

const stock = {
  categories: [
    {
      id: 'cat-a',
      name: 'Apple',
      items: [
        {
          key: 'place-a',
          label: 'Alpha',
          image: { src: 'https://assets.example/a.svg', alt: '🅰️' },
          search: ['Alpha'],
          selection: { id: 'a', custom: false, native: '🅰️' },
        },
        {
          key: 'place-b',
          label: 'Bravo',
          image: { src: 'https://assets.example/b.svg', alt: '🅱️' },
          search: ['Bravo'],
          selection: { id: 'b', custom: false, native: '🅱️' },
        },
      ],
    },
  ],
};

describe('StockEmojiPicker long-press vs short tap', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    openEmojiActions.mockClear();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('inserts on the next short tap after a long-press opened the menu', () => {
    const onPick = jest.fn();
    render(<StockEmojiPicker stock={stock} onPick={onPick} />);

    const alpha = screen.getByRole('button', { name: 'Alpha' });
    const bravo = screen.getByRole('button', { name: 'Bravo' });
    const longTouch = { identifier: 11, clientX: 4, clientY: 4 };

    fireEvent.touchStart(alpha, { touches: [longTouch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    // Native long-press stops this touchend; React never clears a sticky flag.
    fireEvent.touchEnd(alpha, { changedTouches: [longTouch] });

    expect(openEmojiActions).toHaveBeenCalledTimes(1);
    expect(onPick).not.toHaveBeenCalled();

    const shortTouch = { identifier: 12, clientX: 8, clientY: 8 };
    fireEvent.touchStart(bravo, { touches: [shortTouch] });
    fireEvent.touchEnd(bravo, { changedTouches: [shortTouch] });

    expect(onPick).toHaveBeenCalledTimes(1);
    expect(onPick.mock.calls[0][0]).toEqual({ id: 'b', custom: false, native: '🅱️' });
  });

  it('also recovers after a mouse long-press with no touchend path', () => {
    const onPick = jest.fn();
    render(<StockEmojiPicker stock={stock} onPick={onPick} />);

    const alpha = screen.getByRole('button', { name: 'Alpha' });
    const bravo = screen.getByRole('button', { name: 'Bravo' });

    fireEvent.pointerDown(alpha, { button: 0, pointerId: 1, pointerType: 'mouse', clientX: 0, clientY: 0 });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    fireEvent.pointerUp(alpha, { button: 0, pointerId: 1, pointerType: 'mouse', clientX: 0, clientY: 0 });

    expect(openEmojiActions).toHaveBeenCalledTimes(1);

    fireEvent.click(bravo, { detail: 1 });
    expect(onPick).toHaveBeenCalledTimes(1);
    expect(onPick.mock.calls[0][0].native).toBe('🅱️');
  });
});
