export const STILL_IMAGE_CONTENT_TYPES = [
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/jxl',
];

// The server decides animated GIF and mislabeled video. The composer
// refuses types it already knows are audio or video.
export const delegatedFileIsBlocked = file => {
  const type = file && typeof file.type === 'string' ? file.type.toLowerCase() : '';

  if (type === '') {
    return false;
  }

  if (type.startsWith('video/') || type.startsWith('audio/')) {
    return true;
  }

  return !STILL_IMAGE_CONTENT_TYPES.includes(type);
};
