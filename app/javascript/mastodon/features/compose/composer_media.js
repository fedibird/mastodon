export const COMPACT_MEDIA_PREVIEW_LIMIT = 4;

export function moveMediaIds (ids, id, toIndex) {
  const list = Array.isArray(ids) ? ids.slice() : [];
  const from = list.indexOf(id);

  if (from < 0 || !Number.isInteger(toIndex)) {
    return list;
  }

  const dest = Math.max(0, Math.min(list.length - 1, toIndex));

  if (from === dest) {
    return list;
  }

  const [item] = list.splice(from, 1);
  list.splice(dest, 0, item);

  return list;
}

export function summaryThumbCount ({
  width,
  itemCount,
  reserved = 44,
  thumb = 40,
  more = 40,
  max = COMPACT_MEDIA_PREVIEW_LIMIT,
} = {}) {
  const count = Math.max(0, itemCount || 0);
  const cap = Math.max(0, max);

  if (!width || width <= 0) {
    return Math.min(count, cap);
  }

  const room = Math.max(0, width - reserved);

  if (count <= cap && count * thumb <= room) {
    return count;
  }

  return Math.max(0, Math.min(cap, Math.floor((room - more) / thumb)));
}

export const isExclusiveAttachmentType = (type) => type === 'video' || type === 'audio' || type === 'gifv';

export const isExclusiveFile = (mime) => (
  typeof mime === 'string' && (mime.startsWith('video/') || mime.startsWith('audio/'))
);

export function attachmentUploadBlocked ({
  existingTypes = [],
  pending = 0,
  pendingExclusive = 0,
  incomingMimeTypes = [],
} = {}) {
  if (!incomingMimeTypes.length) {
    return false;
  }

  if (pendingExclusive > 0 || existingTypes.some(isExclusiveAttachmentType)) {
    return true;
  }

  const exclusiveIncoming = incomingMimeTypes.filter(isExclusiveFile);

  if (!exclusiveIncoming.length) {
    return false;
  }

  if (exclusiveIncoming.length > 1) {
    return true;
  }

  return existingTypes.length > 0 || pending > 0 || incomingMimeTypes.length > 1;
}

export function composerFileDropBlock ({
  canUpload = true,
  permissionReason = null,
  existingTypes = [],
  mediaCount = 0,
  pending = 0,
  pendingExclusive = 0,
  maxAttachments = Infinity,
  hasPoll = false,
  allowPollImage = true,
  incomingMimeTypes = null,
} = {}) {
  if (canUpload === false) {
    return permissionReason || 'unauthorized';
  }

  if (!allowPollImage && hasPoll) {
    return 'poll_image';
  }

  if (pendingExclusive > 0 || existingTypes.some(isExclusiveAttachmentType)) {
    return 'video';
  }

  if (Array.isArray(incomingMimeTypes) && attachmentUploadBlocked({
    existingTypes,
    pending,
    pendingExclusive,
    incomingMimeTypes,
  })) {
    return 'video';
  }

  const occupied = (mediaCount || 0) + (pending || 0);
  const incomingCount = Array.isArray(incomingMimeTypes) ? incomingMimeTypes.length : null;

  if (incomingCount === null) {
    if (occupied >= maxAttachments) {
      return 'limit';
    }
  } else if (occupied + incomingCount > maxAttachments) {
    return 'limit';
  }

  return null;
}

export function visibleMediaWindow (ids, { summary = false, expanded = false, limit = COMPACT_MEDIA_PREVIEW_LIMIT } = {}) {
  const list = Array.isArray(ids) ? ids : [];

  if (!summary || expanded || list.length <= limit) {
    return { visible: list.slice(), overflow: 0 };
  }

  return {
    visible: list.slice(0, limit),
    overflow: list.length - limit,
  };
}
