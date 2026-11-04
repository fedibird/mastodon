import React from 'react';
import { act, fireEvent, render } from '@testing-library/react';

import TimelineCardBody from '../timeline_card_body';

describe('TimelineCardBody', () => {
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

  const setScrollMetrics = (viewport, scrollHeight, clientHeight) => {
    Object.defineProperty(viewport, 'scrollHeight', { configurable: true, value: scrollHeight });
    Object.defineProperty(viewport, 'clientHeight', { configurable: true, value: clientHeight });

    act(() => {
      observers[0].callback([]);
    });
  };

  const renderBody = (text = 'A long post') => render(
    <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text'>
      <p>{text}</p>
    </TimelineCardBody>,
  );

  it('keeps short or exactly ten-line text unexpanded, with no ▼ button', () => {
    const { container, queryByRole } = renderBody('Short post');
    const viewport = container.querySelector('.timeline-card__body-scroll');

    expect(observers).toHaveLength(1);
    expect(observers[0].observe).toHaveBeenCalledTimes(2);

    setScrollMetrics(viewport, 200, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(viewport.getAttribute('tabindex')).toBeNull();
    expect(viewport.textContent).toBe('Short post');
  });

  it('scrolls only the text region and expands it fully without navigating the card', () => {
    const onNavigate = jest.fn();
    const { container, getByRole, queryByRole } = render(
      <div role='button' tabIndex='0' onClick={onNavigate} onKeyDown={onNavigate}>
        <div data-testid='first-media'>first image</div>
        <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text'>
          <p>Long text</p>
        </TimelineCardBody>
        <div data-testid='author'>author</div>
      </div>,
    );

    const viewport = container.querySelector('.timeline-card__body-scroll');
    setScrollMetrics(viewport, 300, 200);

    expect(getByRole('button', { name: 'Show full post text' }).textContent).toBe('▼');
    expect(viewport.getAttribute('tabindex')).toBe('0');
    expect(viewport.getAttribute('aria-label')).toBe('Scrollable post text');
    expect(viewport.textContent).toBe('Long text');
    expect(container.querySelector('[data-testid="first-media"]').closest('.timeline-card__body')).toBeNull();
    expect(container.querySelector('[data-testid="author"]').closest('.timeline-card__body')).toBeNull();

    fireEvent.click(getByRole('button', { name: 'Show full post text' }));

    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(container.querySelector('.timeline-card__body--expanded')).not.toBeNull();
    expect(viewport.getAttribute('tabindex')).toBe('-1');
    expect(document.activeElement).toBe(viewport);
    expect(onNavigate).not.toHaveBeenCalled();
  });

  it('updates the ▼ affordance when text or wrapping changes inside a capped card', () => {
    const { container, rerender, queryByRole } = renderBody();
    const viewport = container.querySelector('.timeline-card__body-scroll');

    setScrollMetrics(viewport, 201, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();

    rerender(
      <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text'>
        <p>Translated text that wraps into more lines</p>
      </TimelineCardBody>,
    );
    setScrollMetrics(viewport, 310, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).not.toBeNull();

    setScrollMetrics(viewport, 195, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(viewport.getAttribute('tabindex')).toBeNull();
  });

  it('detects overflow after a window resize without ResizeObserver', () => {
    window.ResizeObserver = undefined;
    const { container, getByRole } = renderBody();
    const viewport = container.querySelector('.timeline-card__body-scroll');

    Object.defineProperty(viewport, 'scrollHeight', { configurable: true, value: 400 });
    Object.defineProperty(viewport, 'clientHeight', { configurable: true, value: 200 });
    fireEvent(window, new Event('resize'));

    expect(getByRole('button', { name: 'Show full post text' })).not.toBeNull();
  });
});
