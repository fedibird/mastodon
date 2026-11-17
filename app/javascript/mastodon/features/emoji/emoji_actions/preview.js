import unicodeMapping from '../emoji_unicode_mapping_light';

// A preview is display-only. The typed reference remains the identity; neither
// the image URL nor its text is sent back as an emoji reference.
export function buildEmojiActionsPreview(reference, resolved, anchor) {
  if (!reference) {
    return null;
  }

  const detail = resolved?.detail || {};
  const current = resolved?.reference || reference;
  const anchorImage = anchor?.matches?.('img') ? anchor : anchor?.querySelector?.('img');
  const existingSrc = anchorImage?.currentSrc || anchorImage?.getAttribute('src') || null;

  if (current.kind === 'unicode') {
    const native = current.native;
    const shortcode = unicodeMapping[native]?.shortCode;

    return {
      native,
      imageSrc: existingSrc || detail.image?.src || null,
      name: detail.label || null,
      shortcode: shortcode ? `:${shortcode}:` : null,
    };
  }

  if (current.kind !== 'custom') {
    return null;
  }

  const emoji = detail.emoji || {};
  // Enlarge the actual visible glyph first, not a different row reused under a shortcode.
  const imageSrc = existingSrc || emoji.static_url || emoji.url || null;

  // No new remote fetch just to supply a preview: an unfetched remote emoji
  // stays metadata-only instead of inventing a preview or fetching its URL.
  if (!imageSrc) {
    return null;
  }

  const shortcode = current.shortcode || emoji.shortcode;
  const suffix = current.scope === 'remote' && current.domain ? `@${current.domain}` : '';

  return {
    native: null,
    imageSrc,
    name: emoji.alternate_name || null,
    shortcode: shortcode ? `:${shortcode}${suffix}:` : null,
  };
}

const clamp = (value, min, max) => Math.max(min, Math.min(max, value));

// The preview is absolutely positioned relative to the existing Popper menu.
// It never participates in Popper size calculation or the menu hit-test.
// If the viewport cannot fit both, return null: actions take priority.
export function positionEmojiActionsPreview(menu, preview, viewport) {
  if (!menu || !preview || !viewport || !preview.width || !preview.height) {
    return null;
  }

  const edge = 8;
  const gap = 8;
  // Hidden measurement must never create a horizontal/vertical scroll area.
  if (preview.width > viewport.width - edge * 2 || preview.height > viewport.height - edge * 2) {
    return null;
  }
  const left = clamp(menu.left + (menu.width - preview.width) / 2, edge, viewport.width - preview.width - edge);
  const top = clamp(menu.top, edge, viewport.height - preview.height - edge);

  if (menu.top - edge >= preview.height + gap) {
    return { left: left - menu.left, top: -preview.height - gap };
  }

  // At the top edge, keep menu items next to the activation point and put
  // the preview beside the menu when the screen has horizontal room.
  if (viewport.width - menu.right - edge >= preview.width + gap) {
    return { left: menu.width + gap, top: top - menu.top };
  }

  if (menu.left - edge >= preview.width + gap) {
    return { left: -preview.width - gap, top: top - menu.top };
  }

  if (viewport.height - menu.bottom - edge >= preview.height + gap) {
    return { left: left - menu.left, top: menu.height + gap };
  }

  return null;
}
