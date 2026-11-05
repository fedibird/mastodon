import React from 'react';
import { act, fireEvent, render } from '@testing-library/react';

import TimelineCardReactions, { showCardEmojiReactions } from '../timeline_card_reactions';

describe('showCardEmojiReactions', () => {
  it('hides the card list for compact mode, disabled reactions, and empty counts', () => {
    expect(showCardEmojiReactions(true, true, false)).toBe(true);
    expect(showCardEmojiReactions(true, true, true)).toBe(false);
    expect(showCardEmojiReactions(true, false, false)).toBe(false);
    expect(showCardEmojiReactions(false, true, false)).toBe(false);
  });
});

describe('TimelineCardReactions', () => {
  const originalResizeObserver = window.ResizeObserver;
  let observers;

  beforeEach(() => {
    observers = [];
    window.ResizeObserver = jest.fn().mockImplementation(callback => {
      const observer = {
        callback,
        observe: jest.fn(),
        disconnect: jest.fn(),
      };
      observers.push(observer);
      return observer;
    });
  });

  afterEach(() => {
    window.ResizeObserver = originalResizeObserver;
  });

  const setWidth = (scroller, scrollWidth, clientWidth) => {
    Object.defineProperty(scroller, 'scrollWidth', { configurable: true, value: scrollWidth });
    Object.defineProperty(scroller, 'clientWidth', { configurable: true, value: clientWidth });
    act(() => {
      observers[0].callback([]);
    });
  };

  const renderRow = (singleLine = true) => render(
    <TimelineCardReactions singleLine={singleLine} expandLabel='Show all emoji reactions' scrollLabel='Scrollable emoji reactions'>
      <span data-testid='emoji-reaction-bar'>reactions</span>
    </TimelineCardReactions>,
  );

  it('shows ▼ only when the single line actually overflows, outside the scroll area', () => {
    const onCard = jest.fn();
    const { container, getByRole, queryByRole, rerender } = render(
      <div role='button' tabIndex='0' onClick={onCard}>
        <TimelineCardReactions singleLine expandLabel='Show all emoji reactions' scrollLabel='Scrollable emoji reactions'>
          <span data-testid='emoji-reaction-bar'>reactions</span>
        </TimelineCardReactions>
      </div>,
    );
    const scroller = container.querySelector('.timeline-card__reactions-scroll');

    setWidth(scroller, 120, 120);
    expect(queryByRole('button', { name: 'Show all emoji reactions' })).toBeNull();

    setWidth(scroller, 420, 120);
    const button = getByRole('button', { name: 'Show all emoji reactions' });
    expect(button.textContent).toBe('▼');
    expect(scroller.contains(button)).toBe(false);
    expect(scroller.getAttribute('aria-label')).toBe('Scrollable emoji reactions');

    fireEvent.click(button);
    expect(onCard).not.toHaveBeenCalled();
    expect(queryByRole('button', { name: 'Show all emoji reactions' })).toBeNull();
    expect(container.querySelector('.timeline-card__reactions--wrapped')).not.toBeNull();
    expect(document.activeElement).toBe(scroller);

    rerender(
      <div role='button' tabIndex='0' onClick={onCard}>
        <TimelineCardReactions singleLine expandLabel='Show all emoji reactions' scrollLabel='Scrollable emoji reactions'>
          <span data-testid='emoji-reaction-bar'>more reactions</span>
        </TimelineCardReactions>
      </div>,
    );
    expect(container.querySelector('.timeline-card__reactions--wrapped')).not.toBeNull();
    expect(queryByRole('button', { name: 'Show all emoji reactions' })).toBeNull();
  });

  it('wraps without ▼ when the single-line preference is off', () => {
    const { container, queryByRole } = renderRow(false);
    const scroller = container.querySelector('.timeline-card__reactions-scroll');

    Object.defineProperty(scroller, 'scrollWidth', { configurable: true, value: 900 });
    Object.defineProperty(scroller, 'clientWidth', { configurable: true, value: 100 });

    expect(container.querySelector('.timeline-card__reactions--wrapped')).not.toBeNull();
    expect(queryByRole('button', { name: 'Show all emoji reactions' })).toBeNull();
    expect(container.querySelector('[data-testid="emoji-reaction-bar"]')).not.toBeNull();
  });

  it('detects horizontal overflow after a window resize without ResizeObserver', () => {
    window.ResizeObserver = undefined;
    const { container, getByRole } = renderRow(true);
    const scroller = container.querySelector('.timeline-card__reactions-scroll');

    Object.defineProperty(scroller, 'scrollWidth', { configurable: true, value: 500 });
    Object.defineProperty(scroller, 'clientWidth', { configurable: true, value: 80 });
    fireEvent(window, new Event('resize'));

    expect(getByRole('button', { name: 'Show all emoji reactions' })).not.toBeNull();
  });
});
