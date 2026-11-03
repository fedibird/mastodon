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

  const aspect = Number(attachment.getIn(['meta', 'original', 'aspect']))
    || Number(attachment.getIn(['meta', 'small', 'aspect']));
  if (Number.isFinite(aspect) && aspect > 0) {
    return { width: 960, height: Math.max(1, Math.round(960 / aspect)) };
  }

  // A practical initial footprint until the browser reads video metadata.
  return { width: 960, height: 540 };
};

// Deliberately enlarge low-resolution poster images in the lightbox. The
// modal frame is sized before video metadata loads and stays the same once
// playback begins, so the thumbnail's intrinsic size cannot shrink it.
// Limit the frame to 960px, the viewport width, and 80vh in both directions.
export const modalVideoFrameStyle = ({ width, height }) => ({
  '--modal-video-aspect': `${width} / ${height}`,
  '--modal-video-width-by-height': `${Number((80 * width / height).toFixed(3))}vh`,
});
