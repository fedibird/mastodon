// One Escape closes only the highest registered surface. Menus claim the
// key during keydown so the shared keyup listener does not close a layer too.
const layers = new Map();
let listenerInstalled = false;
let keyGeneration = 0;
let claimedGeneration = -1;

const isEscape = (event) => event.key === 'Escape' || event.key === 'Esc' || event.keyCode === 27;

const onKeyDownCapture = () => {
  keyGeneration += 1;
};

const onKeyUp = (event) => {
  if (!isEscape(event) || layers.size === 0 || claimedGeneration === keyGeneration) {
    return;
  }

  const top = topOverlayLayer();

  if (!top || typeof top.onEscape !== 'function') {
    return;
  }

  event.preventDefault();
  event.stopPropagation();
  top.onEscape();
};

const ensureListener = () => {
  if (listenerInstalled || typeof window === 'undefined') {
    return;
  }

  window.addEventListener('keydown', onKeyDownCapture, true);
  window.addEventListener('keyup', onKeyUp, false);
  listenerInstalled = true;
};

const removeListener = () => {
  if (!listenerInstalled || typeof window === 'undefined') {
    return;
  }

  window.removeEventListener('keydown', onKeyDownCapture, true);
  window.removeEventListener('keyup', onKeyUp, false);
  listenerInstalled = false;
};

export const claimEscape = (event) => {
  claimedGeneration = keyGeneration;

  if (event) {
    event.preventDefault();
    event.stopPropagation();
  }
};

export const topOverlayLayer = () => {
  let top = null;

  layers.forEach((layer) => {
    if (!top || layer.priority > top.priority || (layer.priority === top.priority && layer.order > top.order)) {
      top = layer;
    }
  });

  return top;
};

export const isTopOverlayLayer = (id) => {
  const top = topOverlayLayer();
  return !!top && top.id === id;
};

export const hasOverlayLayers = () => layers.size > 0;

export const registerOverlayLayer = ({ id, priority, onEscape }) => {
  const order = layers.size + 1;
  layers.set(id, { id, priority, onEscape, order });
  ensureListener();

  return () => {
    layers.delete(id);

    if (layers.size === 0) {
      removeListener();
    }
  };
};

export const resetOverlayLayersForTests = () => {
  layers.clear();
  removeListener();
  keyGeneration = 0;
  claimedGeneration = -1;
};
