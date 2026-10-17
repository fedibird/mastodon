// Versioned timeline position and anchor geometry.
// Pure: no DOM, scroll, storage, or network. Callers persist nothing from here.

export const TIMELINE_ANCHOR_VERSION = 1;

export const TIMELINE_ANCHOR_REASONS = Object.freeze({
  EMPTY: 'empty',
  NOT_FOUND: 'not_found',
  NOT_LOADED: 'not_loaded',
  INVALID: 'invalid',
  MISSING_HOST: 'missing_host',
  STALE: 'stale',
});

export const SCROLL_HOST_KINDS = Object.freeze(['document', 'pane', 'live', 'history']);

export const TIMELINE_ANCHOR_ALIGNMENTS = Object.freeze(['top', 'center']);

const DECIMAL_STATUS_ID = /^(?:0|[1-9]\d*)$/;
const DISPLAY_ROW_ID = /^[0-9A-Za-z][0-9A-Za-z:_-]{0,127}$/;
const CONDITION_KEY = /^[A-Za-z0-9_:-]{1,64}$/;

export const isDecimalStatusId = (value) => (
  typeof value === 'string' && DECIMAL_STATUS_ID.test(value)
);

// article[data-id] text. Ordinary rows are decimal snowflakes. Featured rows
// already use an f- prefix. Never coerce through Number(): ids exceed 2^53.
export const isDisplayRowId = (value) => (
  typeof value === 'string' && DISPLAY_ROW_ID.test(value)
);

export const isScrollHostKind = (value) => SCROLL_HOST_KINDS.indexOf(value) !== -1;

export const isInnerScrollHostKind = (value) => (
  value === 'pane' || value === 'live' || value === 'history'
);

const finite = (value) => typeof value === 'number' && Number.isFinite(value);

const copyAnchor = (anchor) => {
  const next = {
    version: TIMELINE_ANCHOR_VERSION,
    statusId: anchor.statusId,
    offsetPx: anchor.offsetPx,
    alignment: anchor.alignment,
  };

  if (anchor.fallbackScrollTop !== undefined) {
    next.fallbackScrollTop = anchor.fallbackScrollTop;
  }

  if (anchor.capturedAt !== undefined) {
    next.capturedAt = anchor.capturedAt;
  }

  return next;
};

export const decodeTimelineAnchor = (input) => {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
  }

  if (input.version !== TIMELINE_ANCHOR_VERSION) {
    return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
  }

  let statusId = null;

  if (input.statusId !== null && input.statusId !== undefined) {
    if (!isDecimalStatusId(input.statusId)) {
      return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
    }

    statusId = input.statusId;
  }

  if (!finite(input.offsetPx)) {
    return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
  }

  if (TIMELINE_ANCHOR_ALIGNMENTS.indexOf(input.alignment) === -1) {
    return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
  }

  const anchor = {
    version: TIMELINE_ANCHOR_VERSION,
    statusId,
    offsetPx: input.offsetPx,
    alignment: input.alignment,
  };

  if (input.fallbackScrollTop !== undefined) {
    if (!finite(input.fallbackScrollTop)) {
      return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
    }

    anchor.fallbackScrollTop = input.fallbackScrollTop;
  }

  if (input.capturedAt !== undefined) {
    if (typeof input.capturedAt !== 'string' || Number.isNaN(Date.parse(input.capturedAt))) {
      return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
    }

    anchor.capturedAt = input.capturedAt;
  }

  return { ok: true, anchor: copyAnchor(anchor) };
};

// Known fields only. Unknown keys (tokens, account objects) are dropped.
export const encodeTimelineAnchor = (input) => decodeTimelineAnchor(input);

const optionalIdentityString = (value) => {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  if (typeof value !== 'string' || value.length > 256) {
    return null;
  }

  return value;
};

const sanitizeConditions = (conditions) => {
  if (!conditions || typeof conditions !== 'object' || Array.isArray(conditions)) {
    return null;
  }

  const clean = {};

  Object.keys(conditions).forEach((key) => {
    if (!CONDITION_KEY.test(key)) {
      return;
    }

    const value = conditions[key];

    if (typeof value === 'string') {
      if (value.length <= 256) {
        clean[key] = value;
      }

      return;
    }

    if (typeof value === 'boolean' || value === null || finite(value)) {
      clean[key] = value;
    }
  });

  return Object.keys(clean).length > 0 ? clean : null;
};

const sameConditions = (left, right) => {
  if (left === right) {
    return true;
  }

  if (!left || !right) {
    return !left && !right;
  }

  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();

  if (leftKeys.length !== rightKeys.length) {
    return false;
  }

  return leftKeys.every((key, index) => key === rightKeys[index] && left[key] === right[key]);
};

// What timeline this is. Independent of which column is showing it.
export const timelineSourceIdentity = (sourceTimelineId, conditions) => {
  if (typeof sourceTimelineId !== 'string' || sourceTimelineId.length === 0 || sourceTimelineId.length > 256) {
    return null;
  }

  return {
    kind: 'timeline_source',
    sourceTimelineId,
    conditions: sanitizeConditions(conditions),
  };
};

// Which surface is scrolling. The same source in two columns is two views.
export const timelineViewIdentity = ({
  columnId = null,
  scrollKey = null,
  locationKey = null,
  pane = null,
  dataTimelineId = null,
} = {}) => ({
  kind: 'timeline_view',
  columnId: optionalIdentityString(columnId),
  scrollKey: optionalIdentityString(scrollKey),
  locationKey: optionalIdentityString(locationKey),
  pane: optionalIdentityString(pane),
  dataTimelineId: optionalIdentityString(dataTimelineId),
});

export const sameTimelineSource = (left, right) => (
  !!left && !!right &&
  left.kind === 'timeline_source' &&
  right.kind === 'timeline_source' &&
  left.sourceTimelineId === right.sourceTimelineId &&
  sameConditions(left.conditions, right.conditions)
);

export const sameTimelineView = (left, right) => (
  !!left && !!right &&
  left.kind === 'timeline_view' &&
  right.kind === 'timeline_view' &&
  left.columnId === right.columnId &&
  left.scrollKey === right.scrollKey &&
  left.locationKey === right.locationKey &&
  left.pane === right.pane &&
  left.dataTimelineId === right.dataTimelineId
);

export const createTimelinePosition = ({ source, view, anchor } = {}) => {
  if (!source || source.kind !== 'timeline_source' || typeof source.sourceTimelineId !== 'string' || source.sourceTimelineId.length === 0) {
    return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
  }

  if (!view || view.kind !== 'timeline_view') {
    return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
  }

  const decoded = decodeTimelineAnchor(anchor);

  if (!decoded.ok) {
    return decoded;
  }

  return {
    ok: true,
    position: {
      version: TIMELINE_ANCHOR_VERSION,
      source: timelineSourceIdentity(source.sourceTimelineId, source.conditions),
      view: timelineViewIdentity(view),
      anchor: decoded.anchor,
    },
  };
};

// Top: distance from the visible edge to the row top (negative when the row
// starts above the edge). Center: distance from the row top to where that
// top would sit if the row were centered, plus the stored offset.
export const timelineAnchorReferenceTop = ({ alignment, visibleTop, visibleHeight, rowHeight }) => {
  if (alignment === 'center') {
    const viewport = finite(visibleHeight) ? visibleHeight : 0;
    const height = finite(rowHeight) ? rowHeight : 0;

    return visibleTop + (viewport / 2) - (height / 2);
  }

  return visibleTop;
};

export const timelineAnchorDelta = ({ rowTop, rowHeight, visibleTop, visibleHeight, offsetPx, alignment }) => (
  rowTop - timelineAnchorReferenceTop({ alignment, visibleTop, visibleHeight, rowHeight }) - offsetPx
);

export const selectAnchorFromMeasurements = ({ rows, visibleTop, visibleHeight = 0, alignment = 'top' } = {}) => {
  const align = alignment === 'center' ? 'center' : 'top';
  const list = Array.isArray(rows) ? rows : [];
  const viewport = finite(visibleHeight) ? visibleHeight : 0;
  const edge = align === 'center' ? visibleTop + (viewport / 2) : visibleTop;
  const row = list.find(item => item && finite(item.bottom) && item.bottom > edge);

  if (!row || typeof row.rowId !== 'string' || row.rowId.length === 0) {
    return { rowId: null, offsetPx: 0, alignment: align };
  }

  return {
    rowId: row.rowId,
    offsetPx: row.top - timelineAnchorReferenceTop({
      alignment: align,
      visibleTop,
      visibleHeight: viewport,
      rowHeight: row.height,
    }),
    alignment: align,
  };
};
