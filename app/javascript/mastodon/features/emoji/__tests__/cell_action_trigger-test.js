/**
 * @jest-environment jsdom
 */

import { fireEvent } from '@testing-library/react';
import { attachCellActionTriggerHandlers } from '../cell_action_trigger';

describe('attachCellActionTriggerHandlers', () => {
  let trigger;
  let onOpen;
  let detach;

  beforeEach(() => {
    trigger = document.createElement('button');
    document.body.appendChild(trigger);
    onOpen = jest.fn();
    detach = attachCellActionTriggerHandlers(trigger, { onOpen });
  });

  afterEach(() => {
    if (detach) {
      detach();
    }
    document.body.innerHTML = '';
  });

  it('opens on touchend even when no synthetic click follows', () => {
    const touch = { identifier: 1, clientX: 8, clientY: 8 };
    fireEvent.touchStart(trigger, { touches: [touch] });
    fireEvent.touchEnd(trigger, { changedTouches: [touch] });

    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it('suppresses a following click after touchend opened the menu', () => {
    const touch = { identifier: 1, clientX: 8, clientY: 8 };
    fireEvent.touchStart(trigger, { touches: [touch] });
    fireEvent.touchEnd(trigger, { changedTouches: [touch] });
    fireEvent.click(trigger);

    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it('opens from a plain click when no touch gesture ran', () => {
    fireEvent.click(trigger);
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it('does not open when the touch moves beyond the tap threshold', () => {
    fireEvent.touchStart(trigger, { touches: [{ identifier: 1, clientX: 0, clientY: 0 }] });
    fireEvent.touchMove(trigger, { touches: [{ identifier: 1, clientX: 40, clientY: 0 }] });
    fireEvent.touchEnd(trigger, { changedTouches: [{ identifier: 1, clientX: 40, clientY: 0 }] });

    expect(onOpen).not.toHaveBeenCalled();
  });

  it('does not open after touchcancel', () => {
    const touch = { identifier: 1, clientX: 4, clientY: 4 };
    fireEvent.touchStart(trigger, { touches: [touch] });
    fireEvent.touchCancel(trigger, { changedTouches: [touch] });
    fireEvent.touchEnd(trigger, { changedTouches: [touch] });

    expect(onOpen).not.toHaveBeenCalled();
  });
});
