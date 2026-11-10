// Hit-test the shared emoji actions portal by viewport coordinates. Used when
// a long-press release lands on a menu item (touchend/pointerup.target may
// still be the original emoji cell).

export function hitTestEmojiActionsMenuItem(clientX, clientY, rootDocument = document) {
  if (!rootDocument || typeof rootDocument.elementFromPoint !== 'function') {
    return null;
  }

  if (typeof clientX !== 'number' || typeof clientY !== 'number') {
    return null;
  }

  const top = rootDocument.elementFromPoint(clientX, clientY);

  if (!top || typeof top.closest !== 'function') {
    return null;
  }

  const menu = top.closest('[data-emoji-actions-menu="1"]');

  if (!menu) {
    return null;
  }

  const item = top.closest('[data-index]');

  if (!item || !menu.contains(item)) {
    return null;
  }

  if (item.getAttribute('aria-disabled') === 'true') {
    return null;
  }

  const index = Number(item.getAttribute('data-index'));

  if (!Number.isFinite(index) || index < 0) {
    return null;
  }

  return item;
}

export function clearEmojiActionsSlideHighlight(previous) {
  if (previous && previous.classList) {
    previous.classList.remove('emoji-actions-menu__slide-target');
  }
}

export function setEmojiActionsSlideHighlight(previous, next) {
  if (previous === next) {
    return next || null;
  }

  clearEmojiActionsSlideHighlight(previous);

  if (next && next.classList) {
    next.classList.add('emoji-actions-menu__slide-target');
  }

  return next || null;
}
