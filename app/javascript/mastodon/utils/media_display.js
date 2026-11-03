import { displayMedia } from 'mastodon/initial_state';

export const MEDIA_SHAPES = ['square', 'original'];
export const MEDIA_SIZES = ['small', 'medium', 'large', 'max'];
export const MEDIA_VISIBILITY = ['hide_sensitive', 'show_all', 'hide_all'];

export const defaultMediaVisibility = () => (
  displayMedia === 'show_all' || displayMedia === 'hide_all' ? displayMedia : 'hide_sensitive'
);

// A view-only policy; never writes to the user's persistent media preferences.
export const mediaIsConcealed = (visibility, sensitive, cwHidden, revealed = false) => {
  if (revealed) {
    return false;
  }

  if (visibility === 'show_all') {
    return false;
  }

  if (visibility === 'hide_all') {
    return true;
  }

  return !!(sensitive || cwHidden);
};

// Tiles must still shrink on small columns, and maximum is always one tile.
const MEDIA_WIDTHS = { small: 126, medium: 188, large: 254 };
const GAP = 8;
export const mediaMinWidth = size => MEDIA_WIDTHS[size] || MEDIA_WIDTHS.small;

export const mediaColumnsForWidth = (size, width) => (
  size === 'max' ? 1 : Math.max(1, Math.floor((width + GAP) / (mediaMinWidth(size) + GAP)))
);

export const mediaGridColumns = size => (
  size === 'max' ? 'minmax(0, 1fr)' : `repeat(auto-fill, minmax(min(100%, ${mediaMinWidth(size)}px), 1fr))`
);

// Prefer the size of the actual media over an inferred square thumbnail.
export const mediaAspectRatio = attachment => {
  if (!attachment || !attachment.getIn) {
    return null;
  }

  const aspect = Number(attachment.getIn(['meta', 'original', 'aspect']) ||
    attachment.getIn(['meta', 'small', 'aspect']));
  if (Number.isFinite(aspect) && aspect > 0) {
    return aspect;
  }

  const width = Number(attachment.getIn(['meta', 'original', 'width']));
  const height = Number(attachment.getIn(['meta', 'original', 'height']));
  return Number.isFinite(width) && Number.isFinite(height) && height > 0 && width > 0 ? width / height : null;
};
