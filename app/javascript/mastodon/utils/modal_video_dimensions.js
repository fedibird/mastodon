// Video attachment dimensions live in meta.original, not at the top level.
// Use the native dimensions in lightboxes, rather than falling back to the
// browser's 300x150 <video> default. Older remote attachments may only
// have preview dimensions, or no size metadata at all.
const validDimensions = (width, height) => {
  const parsedWidth = Number(width);
  const parsedHeight = Number(height);

  return Number.isFinite(parsedWidth) && parsedWidth > 0 &&
    Number.isFinite(parsedHeight) && parsedHeight > 0
    ? { width: parsedWidth, height: parsedHeight }
    : null;
};

export const modalVideoDimensions = attachment => {
  const original = validDimensions(
    attachment.getIn(['meta', 'original', 'width']),
    attachment.getIn(['meta', 'original', 'height']),
  );
  if (original) return original;

  const direct = validDimensions(attachment.get('width'), attachment.get('height'));
  if (direct) return direct;

  const preview = validDimensions(
    attachment.getIn(['meta', 'small', 'width']),
    attachment.getIn(['meta', 'small', 'height']),
  );
  if (preview) {
    // A thumbnail may be just 96px wide; retain its aspect ratio without
    // treating its resolution as the intended video player size.
    const width = Math.max(960, preview.width);
    return { width, height: Math.round(width * preview.height / preview.width) };
  }

  // A practical initial footprint until the browser reads video metadata.
  return { width: 960, height: 540 };
};
