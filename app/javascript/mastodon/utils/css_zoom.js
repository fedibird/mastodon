// getBoundingClientRect is in viewport pixels after CSS zoom. scrollTop on the
// zoomed scroller stays in that element's unzoomed CSS pixels.
export const usedCssZoom = (element) => {
  if (!element || typeof window === 'undefined' || !window.getComputedStyle) {
    return 1;
  }

  let zoom = 1;
  let node = element;

  while (node && node.nodeType === 1) {
    const raw = window.getComputedStyle(node).zoom;
    const value = parseFloat(raw);

    if (raw && raw !== 'normal' && Number.isFinite(value) && value > 0) {
      zoom *= value;
    }

    node = node.parentElement;
  }

  return zoom || 1;
};

export const scrollTopDeltaForVisualDelta = (visualDelta, zoom) => {
  const factor = Number(zoom);

  if (!Number.isFinite(factor) || factor <= 0) {
    return visualDelta;
  }

  return visualDelta / factor;
};
