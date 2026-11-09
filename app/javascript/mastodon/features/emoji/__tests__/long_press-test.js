/**
 * @jest-environment jsdom
 */

import { fireEvent, act } from '@testing-library/react';
import { attachLongPressGesture, LONG_PRESS_MS } from '../long_press';

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
    node.addEventListener('click', click);

    dispatchPointer(node, 'pointerdown');
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    dispatchPointer(node, 'pointerup');
    fireEvent.click(node);

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(click).not.toHaveBeenCalled();
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

  it('cancels when a second finger lands', () => {
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
});
