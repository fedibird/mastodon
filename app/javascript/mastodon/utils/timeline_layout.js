// Presentation modes are distinct from the existing Status.showCard link-preview flag.
export const TIMELINE_LAYOUT_NORMAL = 'normal';
export const TIMELINE_LAYOUT_MEDIA = 'media';

export const TIMELINE_LAYOUT_OPTIONS = ['normal', 'card-1', 'card-2', 'card-3', 'media'];

export const normalizeTimelineLayout = value => (
  TIMELINE_LAYOUT_OPTIONS.includes(value) ? value : TIMELINE_LAYOUT_NORMAL
);

export const isCardTimelineLayout = value => /^card-[123]$/.test(value);

// Match the fixed column sizes in styles/mastodon/components.scss. Reserve
// 16px for the native scrollbar when choosing a width for a card layout.
const COLUMN_WIDTH_PRESETS = [
  { id: 'x080', pixels: 280 },
  { id: 'x100', pixels: 350 },
  { id: 'x125', pixels: 437.5 },
  { id: 'x150', pixels: 525 },
  { id: 'x200', pixels: 700 },
];
const CARD_MIN_WIDTH = 172;
const CARD_GAP = 8;
const SCROLLBAR_ALLOWANCE = 16;

export const columnWidthForCardLayout = (layoutMode, currentWidth) => {
  const desiredColumns = layoutMode === 'card-2' ? 2 : layoutMode === 'card-3' ? 3 : 0;
  if (!desiredColumns || currentWidth === 'free') {
    return currentWidth;
  }

  const current = COLUMN_WIDTH_PRESETS.find(preset => preset.id === currentWidth);
  if (!current) {
    return currentWidth;
  }

  const minimumWidth = desiredColumns * CARD_MIN_WIDTH + (desiredColumns - 1) * CARD_GAP + SCROLLBAR_ALLOWANCE;
  if (current.pixels >= minimumWidth) {
    return currentWidth;
  }

  const minimumPreset = COLUMN_WIDTH_PRESETS.find(preset => preset.pixels >= minimumWidth);
  return minimumPreset ? minimumPreset.id : currentWidth;
};

export const timelineCardColumnsForWidth = (mode, width) => {
  const requested = Number(normalizeTimelineLayout(mode).replace('card-', '')) || 1;
  // 375px iPhone: two 172px cards plus 8px gutter. A usual 330px
  // multicolumn WebUI column still displays one card.
  return Math.min(requested, Math.max(1, Math.floor((width + 8) / 180)));
};

export const readTimelineLayout = (state, columnId, scope) => {
  if (!scope) {
    return TIMELINE_LAYOUT_NORMAL;
  }

  if (columnId) {
    const columns = state.getIn(['settings', 'columns']);
    const index = columns ? columns.findIndex(column => column.get('uuid') === columnId) : -1;

    return normalizeTimelineLayout(index < 0 ? undefined : columns.get(index).getIn(['params', 'layoutMode']));
  }

  return normalizeTimelineLayout(state.getIn(['settings', scope, 'layoutMode']));
};

// Statuses in the Redux store are normalized; a boost's attachments belong
// to the referenced status, not the boost object itself.
const timelineMediaForStatus = (id, statuses) => {
  const base = statuses && statuses.get(id);
  if (!base) {
    return null;
  }

  const reblogId = base.get('reblog');
  const status = reblogId ? (statuses.get(reblogId) || base) : base;
  return status.get('media_attachments');
};

export const statusHasTimelineMedia = (id, statuses) => {
  const media = timelineMediaForStatus(id, statuses);
  return !!(media && typeof media.some === 'function' && media.some(Boolean));
};

export const mediaRowsForStatuses = (statusIds, statuses) => {
  const rows = [];

  statusIds.forEach((id, position) => {
    if (id === null) {
      rows.push({ kind: 'gap', position });
      return;
    }

    const media = timelineMediaForStatus(id, statuses);

    if (!media || typeof media.forEach !== 'function') {
      return;
    }

    media.forEach((attachment, index) => {
      if (attachment) {
        const attachmentId = attachment.get('id');
        rows.push({
          kind: 'media',
          id,
          mediaIndex: index,
          // An external feed may legitimately attach the same asset twice.
          // Include the sequence position to keep sibling React keys unique.
          key: `media:${id}:${index}:${attachmentId === undefined || attachmentId === null ? 'unknown' : attachmentId}`,
        });
      }
    });
  });

  return rows;
};
