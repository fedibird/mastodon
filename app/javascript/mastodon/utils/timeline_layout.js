// Presentation modes are distinct from the existing Status.showCard link-preview flag.
export const TIMELINE_LAYOUT_NORMAL = 'normal';
export const TIMELINE_LAYOUT_MEDIA = 'media';

export const TIMELINE_LAYOUT_OPTIONS = ['normal', 'card-1', 'card-2', 'card-3', 'media'];

export const normalizeTimelineLayout = value => (
  TIMELINE_LAYOUT_OPTIONS.includes(value) ? value : TIMELINE_LAYOUT_NORMAL
);

export const isCardTimelineLayout = value => /^card-[123]$/.test(value);

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
export const mediaRowsForStatuses = (statusIds, statuses) => {
  const rows = [];

  statusIds.forEach((id, position) => {
    if (id === null) {
      rows.push({ kind: 'gap', position });
      return;
    }

    const base = statuses && statuses.get(id);
    if (!base) {
      return;
    }

    const reblogId = base.get('reblog');
    const status = reblogId ? (statuses.get(reblogId) || base) : base;
    const media = status.get('media_attachments');

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
          key: `media:${id}:${attachmentId === undefined || attachmentId === null ? index : attachmentId}`,
        });
      }
    });
  });

  return rows;
};
