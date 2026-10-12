export function applyNodeRef (ref, node) {
  if (!ref) {
    return;
  }

  if (typeof ref === 'function') {
    ref(node);
    return;
  }

  ref.current = node;
}

export function createOverlayRefBridge () {
  let popperRef = null;
  let node = null;

  const syncPopperRef = (next) => {
    if (next === popperRef) {
      return;
    }

    if (node) {
      applyNodeRef(popperRef, null);
      applyNodeRef(next, node);
    }

    popperRef = next;
  };

  const compose = (nextNode) => {
    node = nextNode;
    applyNodeRef(popperRef, nextNode);
  };

  const getNode = () => node;

  return { syncPopperRef, compose, getNode };
}
