// The media gallery and its lazy-loading placeholder must reserve the same
// dimensions on the first paint, without measuring a potentially unlaid-out
// or subsequently resized Masonry cell.
export const mediaGalleryAspectRatio = (media, { crop = true, standalone = false, quote = false, maxAttachments = 4 } = {}) => {
  const size = media.take(maxAttachments).size;
  const originalAspect = media.size === 1 ? Number(media.getIn([0, 'meta', 'small', 'aspect'])) : null;
  let aspect = (standalone || !crop) && Number.isFinite(originalAspect) && originalAspect > 0
    ? originalAspect : 16 / 9;

  if (quote) {
    aspect *= 2;
  }

  if (size > 4) {
    aspect /= Math.trunc((size + 1) / 2) / 2;
  }

  return aspect;
};
