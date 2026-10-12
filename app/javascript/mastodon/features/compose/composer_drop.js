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

export function dropComposerIdFromEventTarget (target) {
  if (!target || typeof target.closest !== 'function') {
    return null;
  }

  const node = target.closest('[data-drop-composer-id]');

  if (!node) {
    return null;
  }

  return node.getAttribute('data-drop-composer-id') || null;
}

export function dragFeedback (target, dataTransfer, { canUploadPrimary = false } = {}) {
  if (!isExternalFileDrag(dataTransfer)) {
    return { overlay: false, columnId: null };
  }

  const columnId = dropComposerIdFromEventTarget(target);

  if (composerIdFromEventTarget(target) || columnId) {
    return { overlay: false, columnId };
  }

  return { overlay: Boolean(canUploadPrimary), columnId: null };
}

export function planDocumentFileDrop (event, {
  textOnly = false,
  composerCanAccept,
  primaryCanAccept = false,
} = {}) {
  if (!event || textOnly || !isExternalFileDrag(event.dataTransfer)) {
    return { clearDragUi: false, action: 'ignore', composerId: null };
  }

  const ownId = composerIdFromEventTarget(event.target);

  if (dropAlreadyHandled(event) || ownId) {
    return { clearDragUi: true, action: 'composer-owned', composerId: ownId };
  }

  const columnId = dropComposerIdFromEventTarget(event.target);

  if (columnId) {
    if (typeof composerCanAccept === 'function' && !composerCanAccept(columnId)) {
      return { clearDragUi: true, action: 'reject', composerId: columnId };
    }

    return { clearDragUi: true, action: 'upload-composer', composerId: columnId };
  }

  if (primaryCanAccept) {
    return { clearDragUi: true, action: 'upload-primary', composerId: null };
  }

  return { clearDragUi: true, action: 'ignore-primary', composerId: null };
}

export function shouldAcceptGlobalFileDrop (event, { textOnly = false } = {}) {
  const plan = planDocumentFileDrop(event, { textOnly, primaryCanAccept: true });

  return plan.action === 'upload-primary' || plan.action === 'upload-composer';
}

export function syncColumnDropHighlight (target) {
  const column = target && target.closest && target.closest('[data-drop-composer-id]');

  document.querySelectorAll('.column.is-file-drop-target').forEach(node => {
    if (node !== column) {
      node.classList.remove('is-file-drop-target');
    }
  });

  if (column) {
    column.classList.add('is-file-drop-target');
  }
}

export function clearColumnDropHighlight () {
  document.querySelectorAll('.column.is-file-drop-target').forEach(node => {
    node.classList.remove('is-file-drop-target');
  });
}
