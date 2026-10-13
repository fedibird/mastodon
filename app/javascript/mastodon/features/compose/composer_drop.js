import { composerFileDropBlock } from './composer_media';
import { allowPollImage, maxAttachments } from '../../initial_state';

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

const uploadRejectionMessages = {
  missing: { id: 'compose_form.upload_blocked', defaultMessage: 'This posting account can’t attach media here.' },
  media: { id: 'compose_form.upload_blocked.media', defaultMessage: 'This posting account can’t attach media.' },
  reply: { id: 'compose_form.upload_blocked.reply', defaultMessage: 'Replies and quotes can’t include media from this posting account.' },
  quote: { id: 'compose_form.upload_blocked.reply', defaultMessage: 'Replies and quotes can’t include media from this posting account.' },
  poll: { id: 'compose_form.upload_blocked.poll', defaultMessage: 'Remove the poll before attaching media as this posting account.' },
  schedule: { id: 'compose_form.upload_blocked.schedule', defaultMessage: 'Scheduled posts can’t include media from this posting account.' },
  schedule_bound: { id: 'compose_form.upload_blocked.schedule', defaultMessage: 'Scheduled posts can’t include media from this posting account.' },
  group: { id: 'compose_form.upload_blocked.group', defaultMessage: 'Group posts can’t include media from this posting account.' },
  unauthorized: { id: 'compose_form.upload_blocked.unauthorized', defaultMessage: 'This posting account isn’t allowed to attach media.' },
  unregistered: { id: 'compose_form.upload_blocked.unauthorized', defaultMessage: 'This posting account isn’t allowed to attach media.' },
  unsupported: { id: 'compose_form.upload_blocked.unauthorized', defaultMessage: 'This posting account isn’t allowed to attach media.' },
  unresolved: { id: 'compose_form.upload_blocked.unresolved', defaultMessage: 'Still confirming whether this posting account can attach media.' },
  idle: { id: 'compose_form.upload_blocked.unresolved', defaultMessage: 'Still confirming whether this posting account can attach media.' },
  loading: { id: 'compose_form.upload_blocked.unresolved', defaultMessage: 'Still confirming whether this posting account can attach media.' },
  failed: { id: 'compose_form.upload_blocked.failed', defaultMessage: 'Couldn’t confirm whether this posting account can attach media.' },
  mismatch: { id: 'compose_form.upload_blocked.mismatch', defaultMessage: 'This posting account doesn’t match the signed-in account.' },
  edit_bound: { id: 'compose_form.upload_blocked.edit', defaultMessage: 'Finish or discard this edit before attaching media as this posting account.' },
};

export function fileDropBlockFromComposer (composer, permission, incomingMimeTypes = null, {
  maxAttachmentCount = maxAttachments,
  pollImagesAllowed = allowPollImage,
} = {}) {
  if (!composer || !composer.get) {
    return 'missing';
  }

  const media = composer.get('media_attachments');

  return composerFileDropBlock({
    canUpload: !permission || permission.canUpload !== false,
    permissionReason: permission && permission.reason,
    existingTypes: media && media.map ? media.map(item => item.get('type')).toArray() : [],
    mediaCount: media && media.size ? media.size : 0,
    pending: composer.get('pending_media_attachments') || 0,
    pendingExclusive: composer.get('pending_exclusive_attachments') || 0,
    maxAttachments: maxAttachmentCount,
    hasPoll: Boolean(composer.get('poll')),
    allowPollImage: pollImagesAllowed,
    incomingMimeTypes,
  });
}

export function composerFileDropAlert (reason) {
  if (reason === 'poll_image') {
    return { id: 'upload_error.poll', defaultMessage: 'File upload not allowed with polls.' };
  }

  if (reason === 'video') {
    return { id: 'upload_error.video_exclusive', defaultMessage: 'A video or audio file can’t be combined with other attachments.' };
  }

  if (reason === 'limit') {
    return { id: 'upload_error.limit', defaultMessage: 'File upload limit exceeded.' };
  }

  return composerUploadRejectionMessage(reason);
}

export function composerUploadRejectionMessage (reason) {
  return uploadRejectionMessages[reason] || {
    id: 'upload_error.identity',
    defaultMessage: 'This posting account can’t attach media to this post.',
  };
}

export function dragFeedback (target, dataTransfer, { canUploadPrimary = false, composerCanAccept } = {}) {
  if (!isExternalFileDrag(dataTransfer)) {
    return { overlay: false, columnId: null, blocked: false };
  }

  const columnId = dropComposerIdFromEventTarget(target);

  if (composerIdFromEventTarget(target) || columnId) {
    const blocked = Boolean(columnId && typeof composerCanAccept === 'function' && !composerCanAccept(columnId));

    return {
      overlay: false,
      columnId: blocked ? null : columnId,
      blocked,
    };
  }

  return { overlay: Boolean(canUploadPrimary), columnId: null, blocked: false };
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

export function syncColumnDropHighlight (target, { blocked = false } = {}) {
  const column = target && target.closest && target.closest('[data-drop-composer-id]');

  document.querySelectorAll('.column.is-file-drop-target, .column.is-file-drop-blocked').forEach(node => {
    if (node !== column) {
      node.classList.remove('is-file-drop-target', 'is-file-drop-blocked');
    }
  });

  if (!column) {
    return;
  }

  column.classList.toggle('is-file-drop-target', !blocked);
  column.classList.toggle('is-file-drop-blocked', blocked);
}

export function clearColumnDropHighlight () {
  document.querySelectorAll('.column.is-file-drop-target, .column.is-file-drop-blocked').forEach(node => {
    node.classList.remove('is-file-drop-target', 'is-file-drop-blocked');
  });
}
