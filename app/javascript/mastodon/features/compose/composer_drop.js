export function isExternalFileDrag (dataTransfer) {
  if (!dataTransfer || !dataTransfer.types) {
    return false;
  }

  const types = Array.from(dataTransfer.types);

  if (types.indexOf('application/x-fedibird-media-reorder') !== -1) {
    return false;
  }

  return types.indexOf('Files') !== -1;
}

export function composerIdFromEventTarget (target) {
  if (!target || typeof target.closest !== 'function') {
    return null;
  }

  const node = target.closest('[data-composer-id]');

  if (!node) {
    return null;
  }

  return node.getAttribute('data-composer-id') || null;
}

export function markComposerFileDrop (event) {
  if (!event) {
    return;
  }

  event.fedibirdComposerDrop = true;

  if (event.nativeEvent) {
    event.nativeEvent.fedibirdComposerDrop = true;
  }
}

export function dropAlreadyHandled (event) {
  return Boolean(event && (event.fedibirdComposerDrop || (event.nativeEvent && event.nativeEvent.fedibirdComposerDrop)));
}

export function shouldAcceptGlobalFileDrop (event, { textOnly = false } = {}) {
  if (!event || textOnly || dropAlreadyHandled(event) || !isExternalFileDrag(event.dataTransfer)) {
    return false;
  }

  return !composerIdFromEventTarget(event.target);
}
