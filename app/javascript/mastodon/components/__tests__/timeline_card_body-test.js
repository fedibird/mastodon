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
    expect(observers[0].observe).toHaveBeenCalledTimes(3);

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
      <TimelineCardBody expandLabel='Show full post text' scrollLabel='Scrollable post text' collapseLongText={false}>
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

  describe('hold-to-scroll interaction', () => {
    beforeEach(() => jest.useFakeTimers());
    afterEach(() => jest.useRealTimers());

    const hold = () => act(() => {
      jest.advanceTimersByTime(400);
    });

    const collapsedBody = (children = <p>Long text</p>, onClick = () => {}) => {
      const view = render(
        <div className='status__wrapper--compact scrollable' role='button' tabIndex='0' onClick={onClick} onKeyDown={onClick}>
          <TimelineCardBody expandLabel='Show full post text' scrollLabel='Long-press to scroll the post text'>
            {children}
          </TimelineCardBody>
        </div>,
      );
      const viewport = view.container.querySelector('.timeline-card__body-scroll');
      setScrollMetrics(viewport, 400, 200);
      return { ...view, viewport };
    };

    it('leaves wheel scrolling to the timeline until a hold is active', () => {
      const { container, viewport } = collapsedBody();
      expect(container.querySelector('.timeline-card__body--scrollable')).not.toBeNull();
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
      expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(true);
      expect(viewport.scrollTop).toBe(0);
      expect(viewport.tabIndex).toBe(0);
    });

    it('activates after 400ms, scrolls from the same touch, and releases without navigation', () => {
      const onCard = jest.fn();
      const { container, viewport } = collapsedBody(<p>Long text</p>, onCard);
      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 30, clientY: 100 }] });
      act(() => jest.advanceTimersByTime(399));
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
      act(() => jest.advanceTimersByTime(1));
      expect(container.querySelector('.timeline-card__body--hold-active')).not.toBeNull();
      expect(fireEvent.touchMove(viewport, { touches: [{ identifier: 1, clientX: 30, clientY: 65 }] })).toBe(false);
      expect(viewport.scrollTop).toBe(35);
      fireEvent.touchEnd(viewport, { touches: [] });
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
      expect(viewport.scrollTop).toBe(35);
      fireEvent.click(viewport);
      expect(onCard).not.toHaveBeenCalled();
    });

    it('lets an ordinary swipe pass through and never arms after early movement', () => {
      const { container, viewport } = collapsedBody();
      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 30, clientY: 100 }] });
      expect(fireEvent.touchMove(viewport, { touches: [{ identifier: 1, clientX: 30, clientY: 80 }] })).toBe(true);
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
      expect(viewport.scrollTop).toBe(0);
    });


    it('does not attach document-wide mouse listeners until a press starts', () => {
      const { viewport } = collapsedBody();
      const addListener = jest.spyOn(document, 'addEventListener');
      try {
        expect(addListener.mock.calls.filter(([name]) => name === 'mousemove')).toHaveLength(0);
        expect(addListener.mock.calls.filter(([name]) => name === 'mouseup')).toHaveLength(0);

        fireEvent.mouseDown(viewport, { button: 0, clientX: 20, clientY: 100 });
        expect(addListener.mock.calls.filter(([name]) => name === 'mousemove')).toHaveLength(1);
        expect(addListener.mock.calls.filter(([name]) => name === 'mouseup')).toHaveLength(1);

        fireEvent.mouseUp(document, { button: 0, clientX: 20, clientY: 100 });
      } finally {
        addListener.mockRestore();
      }
    });

    it('supports a mouse hold and drag without opening the card on mouseup/click', () => {
      const onCard = jest.fn();
      const { container, viewport } = collapsedBody(<p>Long text</p>, onCard);
      fireEvent.mouseDown(viewport, { button: 0, clientX: 30, clientY: 100 });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).not.toBeNull();
      fireEvent.mouseMove(document, { buttons: 1, clientX: 30, clientY: 65 });
      expect(viewport.scrollTop).toBe(35);
      fireEvent.mouseUp(viewport, { button: 0, clientX: 30, clientY: 65 });
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
      fireEvent.click(viewport);
      expect(onCard).not.toHaveBeenCalled();
    });


    it('does not open the card when a mouse hold ends on a sibling outside the text', () => {
      const onCard = jest.fn();
      const { container, viewport } = collapsedBody(<p>Long text</p>, onCard);
      const card = container.querySelector('.status__wrapper--compact');
      const sibling = document.createElement('div');
      sibling.setAttribute('data-testid', 'card-author');
      card.appendChild(sibling);

      fireEvent.mouseDown(viewport, { button: 0, clientX: 35, clientY: 100 });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).not.toBeNull();

      fireEvent.mouseMove(document, { buttons: 1, clientX: 35, clientY: 60 });
      expect(viewport.scrollTop).toBe(40);
      fireEvent.mouseUp(sibling, { button: 0, clientX: 35, clientY: 60 });
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();

      // Chrome can target the common ancestor rather than the text viewport.
      fireEvent.click(card);
      expect(onCard).not.toHaveBeenCalled();

      // The guard is one-shot. A subsequent intentional click must still open.
      fireEvent.click(card);
      expect(onCard).toHaveBeenCalledTimes(1);
    });

    it('expires the post-hold click guard if Chrome emits no click', () => {
      const onCard = jest.fn();
      const { container, viewport } = collapsedBody(<p>Long text</p>, onCard);
      const card = container.querySelector('.status__wrapper--compact');
      fireEvent.mouseDown(viewport, { button: 0, clientX: 30, clientY: 100 });
      hold();
      fireEvent.mouseUp(card, { button: 0, clientX: 30, clientY: 65 });

      act(() => {
        jest.advanceTimersByTime(101);
      });
      fireEvent.click(card);
      expect(onCard).toHaveBeenCalledTimes(1);
    });

    it('ignores a touch-generated click that bubbles from outside the text', () => {
      const onCard = jest.fn();
      const { container, viewport } = collapsedBody(<p>Long text</p>, onCard);
      const card = container.querySelector('.status__wrapper--compact');
      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 30, clientY: 90 }] });
      hold();
      fireEvent.touchMove(viewport, { touches: [{ identifier: 1, clientX: 30, clientY: 55 }] });
      fireEvent.touchEnd(viewport, { touches: [] });

      fireEvent.click(card);
      expect(onCard).not.toHaveBeenCalled();
      fireEvent.click(card);
      expect(onCard).toHaveBeenCalledTimes(1);
    });


    it('preserves ordinary short card clicks when no hold has activated', () => {
      const onCard = jest.fn();
      const { container, viewport } = collapsedBody(<p>Long text</p>, onCard);
      const card = container.querySelector('.status__wrapper--compact');
      fireEvent.mouseDown(viewport, { button: 0, clientX: 20, clientY: 90 });
      fireEvent.mouseUp(viewport, { button: 0, clientX: 20, clientY: 90 });
      fireEvent.click(card);
      expect(onCard).toHaveBeenCalledTimes(1);
    });

    it('keeps guarding touch clicks through compatibility mouse events', () => {
      const onCard = jest.fn();
      const { container, viewport } = collapsedBody(<p>Long text</p>, onCard);
      const card = container.querySelector('.status__wrapper--compact');
      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 30, clientY: 90 }] });
      hold();
      fireEvent.touchEnd(viewport, { touches: [] });
      fireEvent.mouseDown(viewport, { button: 0, clientX: 30, clientY: 90 });
      fireEvent.mouseUp(viewport, { button: 0, clientX: 30, clientY: 90 });
      fireEvent.click(card);
      expect(onCard).not.toHaveBeenCalled();
    });


    it('does not swallow a new tap on a link after a held gesture', () => {
      const onLink = jest.fn(event => event.preventDefault());
      const { container, viewport } = collapsedBody(<p>Long text</p>);
      const card = container.querySelector('.status__wrapper--compact');
      const link = document.createElement('a');
      link.href = '/post/1';
      link.textContent = 'Author link';
      link.addEventListener('click', onLink);
      card.appendChild(link);

      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 30, clientY: 90 }] });
      hold();
      fireEvent.touchEnd(viewport, { touches: [] });

      // New touch/pointer contact belongs to a separate click, and must
      // clear the one-shot guard before the subsequent link click.
      fireEvent.pointerDown(link, { pointerType: 'touch' });
      fireEvent.click(link);
      expect(onLink).toHaveBeenCalledTimes(1);
    });

    it('releases an active hold if the window loses focus', () => {
      const { container, viewport } = collapsedBody();
      fireEvent.mouseDown(viewport, { button: 0, clientX: 20, clientY: 100 });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).not.toBeNull();

      fireEvent(window, new Event('blur'));
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
    });

    it('yields when the browser marks a touchmove noncancelable', () => {
      const { container, viewport } = collapsedBody();
      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 20, clientY: 100 }] });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).not.toBeNull();

      const event = new Event('touchmove', { bubbles: true, cancelable: false });
      Object.defineProperty(event, 'touches', { value: [{ identifier: 1, clientX: 20, clientY: 60 }] });
      act(() => {
        viewport.dispatchEvent(event);
      });

      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
      expect(viewport.scrollTop).toBe(0);
    });

    it('ignores interactive ancestors outside the body but not buttons inside it', () => {
      const { container, viewport } = collapsedBody(
        <div>
          <span data-testid='plain-text'>Plain text</span>
          <span role='button' tabIndex='0' data-testid='inner-control'>Control</span>
        </div>,
      );

      const plainText = container.querySelector('[data-testid="plain-text"]');
      const control = container.querySelector('[data-testid="inner-control"]');

      // The test wrapper itself is role=button; it must not disable holding
      // anywhere inside the body where there is no interactive descendant.
      fireEvent.touchStart(plainText, { touches: [{ identifier: 1, clientX: 25, clientY: 80 }] });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).not.toBeNull();
      fireEvent.touchEnd(plainText, { touches: [] });
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();

      fireEvent.touchStart(control, { touches: [{ identifier: 1, clientX: 25, clientY: 80 }] });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
      fireEvent.touchEnd(control, { touches: [] });
      expect(viewport.scrollTop).toBe(0);
    });

    it('leaves link clicks intact and does not arm from interactive descendants', () => {
      const onLink = jest.fn(event => event.preventDefault());
      const { container, viewport } = collapsedBody(<a href='/post/1' onClick={onLink}>Read more</a>);
      const link = container.querySelector('a');
      fireEvent.touchStart(link, { touches: [{ identifier: 1, clientX: 30, clientY: 100 }] });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
      fireEvent.touchEnd(link, { touches: [] });
      fireEvent.click(link);
      expect(onLink).toHaveBeenCalledTimes(1);
      expect(viewport.scrollTop).toBe(0);
    });

    it('ignores multiple fingers and stops on touchcancel', () => {
      const { container, viewport } = collapsedBody();
      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 20, clientY: 100 }] });
      fireEvent.touchStart(viewport, { touches: [
        { identifier: 1, clientX: 20, clientY: 100 },
        { identifier: 2, clientX: 50, clientY: 100 },
      ] });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();

      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 20, clientY: 100 }] });
      hold();
      expect(container.querySelector('.timeline-card__body--hold-active')).not.toBeNull();
      fireEvent.touchCancel(viewport, { touches: [] });
      expect(container.querySelector('.timeline-card__body--hold-active')).toBeNull();
    });

    it('cleans up pending timers after unmount', () => {
      const { viewport, unmount } = collapsedBody();
      fireEvent.touchStart(viewport, { touches: [{ identifier: 1, clientX: 20, clientY: 100 }] });
      unmount();
      expect(() => hold()).not.toThrow();
    });
  });

  it('shows a minor overflow at natural height because expanding would shrink the card', () => {
    const { container, queryByRole } = renderBody('Just over ten lines');
    const viewport = container.querySelector('.timeline-card__body-scroll');
    const foldedGuide = container.querySelector('.timeline-card__body-folded-height');
    expect(foldedGuide).not.toBeNull();

    foldedGuide.getBoundingClientRect = () => ({ height: 232 });
    setScrollMetrics(viewport, 220, 200);

    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();
    expect(viewport.getAttribute('tabindex')).toBeNull();

    // Equal height to the capped body plus the expander is also not useful.
    setScrollMetrics(viewport, 232, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();
  });

  it('shows ▼ only if the full body is taller than the capped body plus its button', () => {
    const { container, getByRole, queryByRole } = renderBody();
    const viewport = container.querySelector('.timeline-card__body-scroll');
    const foldedGuide = container.querySelector('.timeline-card__body-folded-height');
    foldedGuide.getBoundingClientRect = () => ({ height: 232 });

    setScrollMetrics(viewport, 233, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();

    setScrollMetrics(viewport, 300, 200);
    expect(getByRole('button', { name: 'Show full post text' })).not.toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).not.toBeNull();

    fireEvent.click(getByRole('button', { name: 'Show full post text' }));
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(container.querySelector('.timeline-card__body--expanded')).not.toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();
  });

  it('recomputes the threshold when the line height or card width changes', () => {
    const { container, queryByRole } = renderBody();
    const viewport = container.querySelector('.timeline-card__body-scroll');
    const foldedGuide = container.querySelector('.timeline-card__body-folded-height');
    let foldedHeight = 232;
    foldedGuide.getBoundingClientRect = () => ({ height: foldedHeight });

    setScrollMetrics(viewport, 260, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).not.toBeNull();

    // Enlarged font/cap makes the same text no longer worth folding.
    foldedHeight = 270;
    act(() => observers[0].callback([]));
    expect(queryByRole('button', { name: 'Show full post text' })).toBeNull();
    expect(container.querySelector('.timeline-card__body--scrollable')).toBeNull();

    // A narrower column makes the text long enough to benefit again.
    setScrollMetrics(viewport, 330, 200);
    expect(queryByRole('button', { name: 'Show full post text' })).not.toBeNull();
  });

});
