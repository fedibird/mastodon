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
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();
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
    expect(container.querySelector('.timeline-card__body--scrollable')).not.toBeNull();
    expect(viewport.getAttribute('aria-label')).toBe('Scrollable post text');
    expect(viewport.textContent).toBe('Long text');
    expect(container.querySelector('[data-testid="first-media"]').closest('.timeline-card__body')).toBeNull();
    expect(container.querySelector('[data-testid="author"]').closest('.timeline-card__body')).toBeNull();

    fireEvent.click(getByRole('button', { name: 'Show full post text' }));

    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(container.querySelector('.timeline-card__body--expanded')).not.toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();
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
    expect(container.querySelector('.timeline-card__body--scrollable')).not.toBeNull();

    setScrollMetrics(viewport, 195, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();
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

  it('shows the full text with no scroller or timeline zone when collapse is off', () => {
    const { container, queryByRole } = render(
      <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text' collapseLongText={false} timelineScrollZone>
        <p>Long text</p>
      </TimelineCardBody>,
    );
    const viewport = container.querySelector('.timeline-card__body-scroll');

    Object.defineProperty(viewport, 'scrollHeight', { configurable: true, value: 800 });
    Object.defineProperty(viewport, 'clientHeight', { configurable: true, value: 100 });

    expect(container.querySelector('.timeline-card__body--natural')).not.toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(viewport.getAttribute('tabindex')).toBeNull();
  });

  it('scrolls the timeline from the inline-end third and leaves links clickable', () => {
    const onLink = jest.fn(event => event.preventDefault());
    const onCard = jest.fn();
    const { container, getByRole } = render(
      <div className='scrollable' data-testid='timeline' role='button' tabIndex='0' onClick={onCard}>
        <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text' scrollZoneLabel='Scrolling here moves the timeline'>
          <a href='/posts/1' onClick={onLink}>read more</a>
        </TimelineCardBody>
      </div>,
    );
    const viewport = container.querySelector('.timeline-card__body-scroll');
    const timeline = container.querySelector('.scrollable');
    viewport.getBoundingClientRect = () => ({ left: 0, top: 0, width: 300, height: 120, right: 300, bottom: 120 });
    setScrollMetrics(viewport, 400, 120);

    // The end-third remains interactive without a decorative overlay.
    expect(container.querySelector('[data-timeline-scroll-zone]')).toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).not.toBeNull();
    expect(viewport.getAttribute('aria-label')).toBe('Scrollable post text. Scrolling here moves the timeline');

    expect(fireEvent.wheel(viewport, { deltaY: 48, deltaX: 0, clientX: 40, clientY: 10 })).toBe(true);
    expect(timeline.scrollTop).toBe(0);

    expect(fireEvent.wheel(viewport, { deltaY: 48, deltaX: 0, clientX: 260, clientY: 10 })).toBe(false);
    expect(timeline.scrollTop).toBe(48);
    expect(onCard).not.toHaveBeenCalled();

    fireEvent.click(container.querySelector('a'));
    expect(onLink).toHaveBeenCalled();
    expect(getByRole('button', { name: 'Show full post text' })).not.toBeNull();
  });

  it('hands a vertical touch in the inline-end third to the timeline', () => {
    const { container } = render(
      <div className='scrollable'>
        <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text'>
          <p>Long text</p>
        </TimelineCardBody>
      </div>,
    );
    const viewport = container.querySelector('.timeline-card__body-scroll');
    const timeline = container.querySelector('.scrollable');
    viewport.getBoundingClientRect = () => ({ left: 0, top: 0, width: 300, height: 120, right: 300, bottom: 120 });
    setScrollMetrics(viewport, 400, 120);

    fireEvent.touchStart(viewport, { touches: [{ clientX: 40, clientY: 80 }] });
    fireEvent.touchMove(viewport, { touches: [{ clientX: 36, clientY: 30 }] });
    expect(timeline.scrollTop).toBe(0);

    fireEvent.touchStart(viewport, { touches: [{ clientX: 270, clientY: 80 }] });
    fireEvent.touchMove(viewport, { touches: [{ clientX: 240, clientY: 72 }] });
    expect(timeline.scrollTop).toBe(0);

    fireEvent.touchMove(viewport, { touches: [{ clientX: 268, clientY: 40 }] });
    expect(timeline.scrollTop).toBe(40);
  });

  it('uses the inline-start edge as the timeline zone in RTL', () => {
    const original = window.getComputedStyle;
    window.getComputedStyle = element => ({
      direction: element.getAttribute('dir') === 'rtl' ? 'rtl' : 'ltr',
    });

    const { container } = render(
      <div className='scrollable'>
        <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text' />
      </div>,
    );
    const viewport = container.querySelector('.timeline-card__body-scroll');
    const timeline = container.querySelector('.scrollable');
    viewport.setAttribute('dir', 'rtl');
    viewport.getBoundingClientRect = () => ({ left: 0, top: 0, width: 300, height: 120, right: 300, bottom: 120 });
    setScrollMetrics(viewport, 400, 120);

    expect(fireEvent.wheel(viewport, { deltaY: 20, deltaX: 0, clientX: 250, clientY: 10 })).toBe(true);
    expect(timeline.scrollTop).toBe(0);
    expect(fireEvent.wheel(viewport, { deltaY: 20, deltaX: 0, clientX: 30, clientY: 10 })).toBe(false);
    expect(timeline.scrollTop).toBe(20);

    window.getComputedStyle = original;
  });

  it('does not install a timeline zone when the preference or the overflow is off', () => {
    const { container, rerender } = render(
      <div className='scrollable'>
        <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text' timelineScrollZone={false} />
      </div>,
    );
    const viewport = container.querySelector('.timeline-card__body-scroll');
    const timeline = container.querySelector('.scrollable');
    viewport.getBoundingClientRect = () => ({ left: 0, top: 0, width: 300, height: 120, right: 300, bottom: 120 });
    setScrollMetrics(viewport, 400, 120);

    expect(container.querySelector('[data-timeline-scroll-zone]')).toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).not.toBeNull();
    expect(viewport.getAttribute('aria-label')).toBe('Scrollable post text');
    expect(fireEvent.wheel(viewport, { deltaY: 30, deltaX: 0, clientX: 280, clientY: 8 })).toBe(true);
    expect(timeline.scrollTop).toBe(0);

    rerender(
      <div className='scrollable'>
        <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text' />
      </div>,
    );
    setScrollMetrics(viewport, 120, 120);
    expect(container.querySelector('[data-timeline-scroll-zone]')).toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();
    expect(viewport.getAttribute('aria-label')).toBeNull();
  });
});
