/**
 * @jest-environment jsdom
 */

import { fireEvent, act } from '@testing-library/react';
import { attachLongPressGesture, LONG_PRESS_MS, LONG_PRESS_CLICK_SUPPRESS_MS } from '../long_press';

function dispatchPointer(node, type, init = {}) {
  const event = new MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    button: 0,
    clientX: 0,
    clientY: 0,
    ...init,
  });
  Object.defineProperty(event, 'pointerId', { value: init.pointerId || 1 });
  Object.defineProperty(event, 'pointerType', { value: init.pointerType || 'mouse' });
  node.dispatchEvent(event);
}

describe('attachLongPressGesture', () => {
  let node;
  let onLongPress;
  let detach;

  beforeEach(() => {
    jest.useFakeTimers();
    node = document.createElement('button');
    document.body.appendChild(node);
    onLongPress = jest.fn();
    detach = attachLongPressGesture(node, { onLongPress });
  });

  afterEach(() => {
    if (detach) {
      detach();
    }
    document.body.innerHTML = '';
    jest.useRealTimers();
  });

  it('fires after holding without movement', () => {
    dispatchPointer(node, 'pointerdown');
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    expect(onLongPress).toHaveBeenCalledTimes(1);
  });

  it('suppresses the following click after a successful long-press', () => {
    const click = jest.fn();
    // Bubble-phase ancestor listener: capture suppress + stopPropagation on the
    // cell must prevent the click from leaving the element.
    document.addEventListener('click', click);

    dispatchPointer(node, 'pointerdown');
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    dispatchPointer(node, 'pointerup');
    fireEvent.click(node, { detail: 1 });

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(click).not.toHaveBeenCalled();
    document.removeEventListener('click', click);
  });

  it('does not fire when the pointer moves beyond the threshold', () => {
    dispatchPointer(node, 'pointerdown');
    dispatchPointer(node, 'pointermove', { clientX: 40, clientY: 0 });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    expect(onLongPress).not.toHaveBeenCalled();
  });

  it('opens from touchstart→hold even when no click follows', () => {
    const touch = { identifier: 7, clientX: 2, clientY: 2 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    fireEvent.touchEnd(node, { changedTouches: [touch] });

    expect(onLongPress).toHaveBeenCalledTimes(1);
  });

  it('cancels when a second finger lands on the same cell', () => {
    fireEvent.touchStart(node, { touches: [{ identifier: 1, clientX: 0, clientY: 0 }] });
    fireEvent.touchMove(node, {
      touches: [
        { identifier: 1, clientX: 0, clientY: 0 },
        { identifier: 2, clientX: 4, clientY: 4 },
      ],
    });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    expect(onLongPress).not.toHaveBeenCalled();
  });

  it('cancels when a second finger lands on a different element', () => {
    const other = document.createElement('button');
    document.body.appendChild(other);

    fireEvent.touchStart(node, { touches: [{ identifier: 1, clientX: 0, clientY: 0 }] });
    fireEvent.touchStart(other, {
      touches: [
        { identifier: 1, clientX: 0, clientY: 0 },
        { identifier: 2, clientX: 10, clientY: 10 },
      ],
    });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    expect(onLongPress).not.toHaveBeenCalled();
  });

  it('stops touchend after a long-press so ancestor/React handlers do not see it', () => {
    // React 17+ listens on the root; same-element listeners still run, but
    // stopPropagation must prevent the event from leaving the cell.
    const hostTouchEnd = jest.fn();
    document.body.addEventListener('touchend', hostTouchEnd);

    const touch = { identifier: 3, clientX: 1, clientY: 1 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    fireEvent.touchEnd(node, { changedTouches: [touch] });

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(hostTouchEnd).not.toHaveBeenCalled();
    document.body.removeEventListener('touchend', hostTouchEnd);
  });

  it('does not suppress keyboard activation (detail=0) after a long-press', () => {
    const click = jest.fn();
    node.addEventListener('click', click);

    const touch = { identifier: 4, clientX: 2, clientY: 2 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    fireEvent.touchEnd(node, { changedTouches: [touch] });

    // No synthetic click arrives; an a11y click within the suppress window must work.
    fireEvent.click(node, { detail: 0 });

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(click).toHaveBeenCalledTimes(1);
  });

  it('allows a new mouse click after a long-press with no synthetic click once a new gesture starts', () => {
    const click = jest.fn();
    node.addEventListener('click', click);

    const touch = { identifier: 5, clientX: 3, clientY: 3 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    fireEvent.touchEnd(node, { changedTouches: [touch] });

    // New intentional press clears leftover suppress.
    dispatchPointer(node, 'pointerdown');
    dispatchPointer(node, 'pointerup');
    fireEvent.click(node, { detail: 1 });

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(click).toHaveBeenCalledTimes(1);
  });

  it('still suppresses one synthetic click after long-press within the window', () => {
    const click = jest.fn();
    document.addEventListener('click', click);

    dispatchPointer(node, 'pointerdown');
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    dispatchPointer(node, 'pointerup');
    fireEvent.click(node, { detail: 1 });

    expect(click).not.toHaveBeenCalled();

    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_CLICK_SUPPRESS_MS + 20);
    });
    fireEvent.click(node, { detail: 1 });
    expect(click).toHaveBeenCalledTimes(1);
    document.removeEventListener('click', click);
  });
});
