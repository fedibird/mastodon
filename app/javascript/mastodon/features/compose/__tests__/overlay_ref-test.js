import { applyNodeRef, createOverlayRefBridge } from '../overlay_ref';

describe('overlay ref bridge', () => {
  it('notifies function refs, object refs, unmount, and a replaced popper ref', () => {
    const first = jest.fn();
    const second = jest.fn();
    const objectRef = { current: null };
    const bridge = createOverlayRefBridge();
    const node = document.createElement('div');

    applyNodeRef(first, node);
    applyNodeRef(objectRef, node);
    applyNodeRef(null, node);

    expect(first).toHaveBeenCalledWith(node);
    expect(objectRef.current).toBe(node);

    bridge.syncPopperRef(first);
    bridge.compose(node);

    expect(first).toHaveBeenLastCalledWith(node);
    expect(bridge.getNode()).toBe(node);

    bridge.syncPopperRef(first);
    expect(first).toHaveBeenCalledTimes(2);

    bridge.syncPopperRef(second);

    expect(first).toHaveBeenLastCalledWith(null);
    expect(second).toHaveBeenCalledWith(node);
    expect(bridge.getNode()).toBe(node);

    bridge.compose(null);

    expect(second).toHaveBeenLastCalledWith(null);
    expect(bridge.getNode()).toBeNull();

    bridge.syncPopperRef(objectRef);
    bridge.compose(node);

    expect(objectRef.current).toBe(node);

    const replacement = { current: 'stale' };

    bridge.syncPopperRef(replacement);

    expect(objectRef.current).toBeNull();
    expect(replacement.current).toBe(node);
  });
});
