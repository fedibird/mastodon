/**
 * @jest-environment jsdom
 */

import { fireEvent, act } from '@testing-library/react';
import {
  resetEmojiActionsBusForTests,
  setEmojiActionsSlideListeners,
} from '../emoji_actions/bus';
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
    resetEmojiActionsBusForTests();
    node = document.createElement('button');
    document.body.appendChild(node);
    onLongPress = jest.fn();
    detach = attachLongPressGesture(node, { onLongPress });
  });

  afterEach(() => {
    if (detach) {
      detach();
    }
    resetEmojiActionsBusForTests();
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

  it('stops non-cancelable touchend after a long-press without requiring preventDefault', () => {
    const hostTouchEnd = jest.fn();
    document.body.addEventListener('touchend', hostTouchEnd);

    const touch = { identifier: 8, clientX: 5, clientY: 5 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    const touchEnd = new Event('touchend', { bubbles: true, cancelable: false });
    Object.defineProperty(touchEnd, 'changedTouches', { value: [touch] });
    Object.defineProperty(touchEnd, 'touches', { value: [] });
    node.dispatchEvent(touchEnd);

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(hostTouchEnd).not.toHaveBeenCalled();
    expect(touchEnd.cancelable).toBe(false);
    document.body.removeEventListener('touchend', hostTouchEnd);
  });

  it('stops non-cancelable pointerup after a long-press', () => {
    const hostPointerUp = jest.fn();
    document.body.addEventListener('pointerup', hostPointerUp);

    dispatchPointer(node, 'pointerdown');
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    const pointerUp = new MouseEvent('pointerup', {
      bubbles: true,
      cancelable: false,
      button: 0,
      clientX: 0,
      clientY: 0,
    });
    Object.defineProperty(pointerUp, 'pointerId', { value: 1 });
    Object.defineProperty(pointerUp, 'pointerType', { value: 'mouse' });
    node.dispatchEvent(pointerUp);

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(hostPointerUp).not.toHaveBeenCalled();
    document.body.removeEventListener('pointerup', hostPointerUp);
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

  it('suppresses the click after a multi-second mouse hold (armed at pointerup)', () => {
    const click = jest.fn();
    document.addEventListener('click', click);

    dispatchPointer(node, 'pointerdown');
    act(() => {
      jest.advanceTimersByTime(2000);
    });
    dispatchPointer(node, 'pointerup');
    fireEvent.click(node, { detail: 1 });

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(click).not.toHaveBeenCalled();
    document.removeEventListener('click', click);
  });

  it('suppresses the click after a multi-second touch hold, including non-cancelable touchend', () => {
    const click = jest.fn();
    document.addEventListener('click', click);

    const touch = { identifier: 31, clientX: 1, clientY: 1 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(2000);
    });

    const touchEnd = new Event('touchend', { bubbles: true, cancelable: false });
    Object.defineProperty(touchEnd, 'changedTouches', { value: [touch] });
    Object.defineProperty(touchEnd, 'touches', { value: [] });
    node.dispatchEvent(touchEnd);
    fireEvent.click(node, { detail: 1 });

    expect(onLongPress).toHaveBeenCalledTimes(1);
    expect(click).not.toHaveBeenCalled();
    document.removeEventListener('click', click);
  });

  it('after fire, allows move onto a menu point and reports release coordinates', () => {
    const onMove = jest.fn();
    const onRelease = jest.fn();
    setEmojiActionsSlideListeners({ onMove, onRelease });

    dispatchPointer(node, 'pointerdown', { clientX: 10, clientY: 10 });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    expect(onLongPress).toHaveBeenCalledTimes(1);

    // Large move after fire must not cancel the gesture.
    dispatchPointer(node, 'pointermove', { clientX: 80, clientY: 90 });
    expect(onMove).toHaveBeenCalledWith(expect.objectContaining({
      clientX: 80,
      clientY: 90,
      gestureId: expect.any(String),
      anchor: node,
    }));

    dispatchPointer(node, 'pointerup', { clientX: 80, clientY: 90 });
    expect(onRelease).toHaveBeenCalledWith(expect.objectContaining({
      clientX: 80,
      clientY: 90,
      gestureId: expect.any(String),
      anchor: node,
    }));
  });

  it('reports touch release from changedTouches coordinates, not event.target', () => {
    const onRelease = jest.fn();
    setEmojiActionsSlideListeners({ onRelease });

    const touch = { identifier: 44, clientX: 4, clientY: 4 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    const endTouch = { identifier: 44, clientX: 120, clientY: 140 };
    fireEvent.touchEnd(node, { changedTouches: [endTouch], touches: [] });

    expect(onRelease).toHaveBeenCalledWith(expect.objectContaining({
      clientX: 120,
      clientY: 140,
      gestureId: expect.any(String),
      anchor: node,
    }));
  });

  it('does not report slide release when the press never fired', () => {
    const onRelease = jest.fn();
    setEmojiActionsSlideListeners({ onRelease });

    dispatchPointer(node, 'pointerdown');
    dispatchPointer(node, 'pointerup');
    expect(onLongPress).not.toHaveBeenCalled();
    expect(onRelease).not.toHaveBeenCalled();
  });

  it('reports slide release when pointerup lands on a different DOM node (menu item)', () => {
    const onMove = jest.fn();
    const onRelease = jest.fn();
    setEmojiActionsSlideListeners({ onMove, onRelease });

    const menuItem = document.createElement('a');
    menuItem.setAttribute('role', 'button');
    menuItem.textContent = 'Mute emoji';
    document.body.appendChild(menuItem);

    dispatchPointer(node, 'pointerdown', { clientX: 10, clientY: 10 });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    expect(onLongPress).toHaveBeenCalledTimes(1);

    // Deliver move/up to the *other* node — element-only listeners would miss these.
    dispatchPointer(menuItem, 'pointermove', { clientX: 80, clientY: 90 });
    dispatchPointer(menuItem, 'pointerup', { clientX: 80, clientY: 90 });

    expect(onMove).toHaveBeenCalledWith(expect.objectContaining({
      clientX: 80,
      clientY: 90,
      gestureId: expect.any(String),
      anchor: node,
    }));
    expect(onRelease).toHaveBeenCalledWith(expect.objectContaining({
      clientX: 80,
      clientY: 90,
      gestureId: expect.any(String),
      anchor: node,
    }));
  });

  it('cancels slide release when a second finger lands after the menu opens', () => {
    const onRelease = jest.fn();
    const onCancel = jest.fn();
    setEmojiActionsSlideListeners({ onRelease, onCancel });

    const other = document.createElement('button');
    document.body.appendChild(other);

    const touch = { identifier: 7, clientX: 5, clientY: 5 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    expect(onLongPress).toHaveBeenCalledTimes(1);

    // Second finger on another element after fire must cancel slide activation.
    fireEvent.touchStart(other, {
      touches: [
        touch,
        { identifier: 8, clientX: 20, clientY: 20 },
      ],
    });

    expect(onCancel).toHaveBeenCalledWith(expect.objectContaining({
      gestureId: expect.any(String),
      anchor: node,
    }));

    const endOnItem = { identifier: 7, clientX: 90, clientY: 90 };
    fireEvent.touchEnd(node, { changedTouches: [endOnItem], touches: [{ identifier: 8, clientX: 20, clientY: 20 }] });

    expect(onRelease).not.toHaveBeenCalled();
  });

  it('cancels slide release after multitouch on touchmove even when fired', () => {
    const onRelease = jest.fn();
    const onCancel = jest.fn();
    setEmojiActionsSlideListeners({ onRelease, onCancel });

    const touch = { identifier: 9, clientX: 1, clientY: 1 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    fireEvent.touchMove(node, {
      touches: [
        { identifier: 9, clientX: 50, clientY: 50 },
        { identifier: 10, clientX: 60, clientY: 60 },
      ],
    });

    expect(onCancel).toHaveBeenCalledWith(expect.objectContaining({
      gestureId: expect.any(String),
      anchor: node,
    }));

    fireEvent.touchEnd(node, {
      changedTouches: [{ identifier: 9, clientX: 50, clientY: 50 }],
      touches: [{ identifier: 10, clientX: 60, clientY: 60 }],
    });

    expect(onRelease).not.toHaveBeenCalled();
  });

  it('notifies slide cancel on pointercancel after the menu opens', () => {
    const onRelease = jest.fn();
    const onCancel = jest.fn();
    setEmojiActionsSlideListeners({ onRelease, onCancel });

    dispatchPointer(node, 'pointerdown', { clientX: 10, clientY: 10 });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    expect(onLongPress).toHaveBeenCalledTimes(1);

    dispatchPointer(node, 'pointercancel', { clientX: 40, clientY: 40 });

    expect(onCancel).toHaveBeenCalledWith(expect.objectContaining({
      gestureId: expect.any(String),
      anchor: node,
    }));
    expect(onRelease).not.toHaveBeenCalled();
  });

  it('does not use another finger coordinate when tracked id is absent from changedTouches', () => {
    const onRelease = jest.fn();
    setEmojiActionsSlideListeners({ onRelease });

    const touch = { identifier: 11, clientX: 2, clientY: 2 };
    fireEvent.touchStart(node, { touches: [touch] });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });

    // Only the other finger ends — must not fall back to list[0].
    fireEvent.touchEnd(node, {
      changedTouches: [{ identifier: 99, clientX: 200, clientY: 200 }],
      touches: [touch],
    });

    expect(onRelease).not.toHaveBeenCalled();
  });

  it('suppresses host click after a pre-fire drag cancel under pointer capture', () => {
    const click = jest.fn();
    document.addEventListener('click', click);

    const elsewhere = document.createElement('div');
    document.body.appendChild(elsewhere);

    dispatchPointer(node, 'pointerdown', { clientX: 10, clientY: 10 });
    // Move beyond threshold before long-press fires.
    dispatchPointer(elsewhere, 'pointermove', { clientX: 40, clientY: 40 });
    act(() => {
      jest.advanceTimersByTime(LONG_PRESS_MS + 20);
    });
    expect(onLongPress).not.toHaveBeenCalled();

    dispatchPointer(elsewhere, 'pointerup', { clientX: 40, clientY: 40 });
    // Captured/cancelled gestures must not insert/react via synthetic click.
    fireEvent.click(node, { detail: 1 });

    expect(click).not.toHaveBeenCalled();
    document.removeEventListener('click', click);
  });
});
