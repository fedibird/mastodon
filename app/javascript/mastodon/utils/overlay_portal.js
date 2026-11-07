let portalNode = null;

export const setFullscreenOverlayPortal = (node) => {
  portalNode = node || null;
};

export const fullscreenOverlayPortal = () => portalNode;

// Menus opened from the fullscreen column join its portal. Menus opened from
// a higher modal stay on document.body so they are not trapped under it.
export const fullscreenOverlayContainer = (target) => {
  if (portalNode && target && typeof target.closest === 'function' && target.closest('.fullscreen-column-host')) {
    return portalNode;
  }

  return document.body;
};

// Tab stays in the layer that currently holds focus. A covered stream remains
// in the DOM, so visibility alone cannot be the filter.
export const nodesInActiveLayer = (scopeRoot, activeElement, selector) => {
  if (!scopeRoot || typeof scopeRoot.querySelectorAll !== 'function') {
    return [];
  }

  return Array.from(scopeRoot.querySelectorAll(selector)).filter((node) => {
    if (typeof node.closest === 'function' && node.closest('[inert], .fullscreen-column__stream-hold--covered')) {
      return false;
    }

    return node.offsetParent !== null || node === activeElement;
  });
};
