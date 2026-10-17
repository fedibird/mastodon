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
const FEATURED_DISPLAY_ROW = /^f-(0|[1-9]\d*)$/;
const CONDITION_KEY = /^[A-Za-z0-9_:-]{1,64}$/;
const CONTROL_CHARACTER = /[\u0000-\u001F\u007F]/;
const MAX_IDENTITY_LENGTH = 256;
const MAX_CONDITION_KEYS = 32;
const MAX_CONDITION_LIST = 64;

export const isDecimalStatusId = (value) => (
  typeof value === 'string' && DECIMAL_STATUS_ID.test(value)
);

// article[data-id] text. Ordinary rows are decimal snowflakes. Featured rows
// already use an f- prefix. Never coerce through Number(): ids exceed 2^53.
export const isDisplayRowId = (value) => (
  typeof value === 'string' && DISPLAY_ROW_ID.test(value)
);

// Pinned/featured rows use article[data-id="f-${statusId}"]. The status id
// stays the decimal id; the display row id is what restore scrolls to.
// A boost's display row id is the wrapper status id, not the original.
export const statusIdForDisplayRow = (displayRowId) => {
  if (isDecimalStatusId(displayRowId)) {
    return displayRowId;
  }

  const featured = typeof displayRowId === 'string' ? FEATURED_DISPLAY_ROW.exec(displayRowId) : null;

  if (featured && isDecimalStatusId(featured[1])) {
    return featured[1];
  }

  return null;
};

export const displayRowAnchorIds = (displayRowId) => {
  if (displayRowId === null || displayRowId === undefined || displayRowId === '') {
    return { statusId: null, displayRowId: null };
  }

  if (!isDisplayRowId(displayRowId)) {
    return null;
  }

  return {
    statusId: statusIdForDisplayRow(displayRowId),
    displayRowId,
  };
};

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

  if (anchor.displayRowId) {
    next.displayRowId = anchor.displayRowId;
  }

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

  let displayRowId;

  if (input.displayRowId !== undefined && input.displayRowId !== null) {
    if (!isDisplayRowId(input.displayRowId)) {
      return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
    }

    displayRowId = input.displayRowId;
    const impliedStatusId = statusIdForDisplayRow(displayRowId);

    if (statusId && impliedStatusId && statusId !== impliedStatusId) {
      return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
    }

    if (!statusId && impliedStatusId) {
      statusId = impliedStatusId;
    }
  }

  const anchor = {
    version: TIMELINE_ANCHOR_VERSION,
    statusId,
    offsetPx: input.offsetPx,
    alignment: input.alignment,
  };

  if (displayRowId) {
    anchor.displayRowId = displayRowId;
  }

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

// Absent is null. A provided value that is not a bounded string fails the
// whole view, so two invalid column ids cannot collapse into one identity.
const readIdentityString = (value) => {
  if (value === null || value === undefined || value === '') {
    return { ok: true, value: null };
  }

  if (typeof value !== 'string' || value.length > MAX_IDENTITY_LENGTH) {
    return { ok: false };
  }

  return { ok: true, value };
};

const canonicalizeScalar = (value) => {
  if (value === null || typeof value === 'boolean') {
    return { ok: true, value };
  }

  if (typeof value === 'number') {
    return finite(value) ? { ok: true, value } : { ok: false };
  }

  if (typeof value === 'string') {
    if (value.length > MAX_IDENTITY_LENGTH || CONTROL_CHARACTER.test(value)) {
      return { ok: false };
    }

    return { ok: true, value };
  }

  return { ok: false };
};

// Hashtag any/all/none and mix source lists are arrays. Dropping them made
// different timelines compare equal. An unsupported value fails the source
// instead of being stripped.
const canonicalizeConditions = (conditions) => {
  if (conditions === null || conditions === undefined) {
    return { ok: true, value: null };
  }

  if (typeof conditions !== 'object' || Array.isArray(conditions)) {
    return { ok: false };
  }

  const keys = Object.keys(conditions);

  if (keys.length > MAX_CONDITION_KEYS) {
    return { ok: false };
  }

  const clean = {};

  for (let index = 0; index < keys.length; index += 1) {
    const key = keys[index];

    if (!CONDITION_KEY.test(key)) {
      return { ok: false };
    }

    const value = conditions[key];

    if (Array.isArray(value)) {
      if (value.length > MAX_CONDITION_LIST) {
        return { ok: false };
      }

      const copy = [];

      for (let itemIndex = 0; itemIndex < value.length; itemIndex += 1) {
        const item = canonicalizeScalar(value[itemIndex]);

        if (!item.ok) {
          return { ok: false };
        }

        copy.push(item.value);
      }

      clean[key] = copy;
    } else {
      const scalar = canonicalizeScalar(value);

      if (!scalar.ok) {
        return { ok: false };
      }

      clean[key] = scalar.value;
    }
  }

  return { ok: true, value: keys.length > 0 ? clean : null };
};

const sameList = (left, right) => (
  left.length === right.length && left.every((item, index) => item === right[index])
);

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

  return leftKeys.every((key, index) => {
    if (key !== rightKeys[index]) {
      return false;
    }

    const leftValue = left[key];
    const rightValue = right[key];

    if (Array.isArray(leftValue) || Array.isArray(rightValue)) {
      return Array.isArray(leftValue) && Array.isArray(rightValue) && sameList(leftValue, rightValue);
    }

    return leftValue === rightValue;
  });
};

// What timeline this is. Independent of which column is showing it.
export const timelineSourceIdentity = (sourceTimelineId, conditions) => {
  if (typeof sourceTimelineId !== 'string' || sourceTimelineId.length === 0 || sourceTimelineId.length > MAX_IDENTITY_LENGTH) {
    return null;
  }

  const canonical = canonicalizeConditions(conditions);

  if (!canonical.ok) {
    return null;
  }

  return {
    kind: 'timeline_source',
    sourceTimelineId,
    conditions: canonical.value,
  };
};

const VIEW_FIELDS = ['columnId', 'scrollKey', 'locationKey', 'pane', 'dataTimelineId'];

// Which surface is scrolling. The same source in two columns is two views.
// Returns null when a provided field cannot be stored without collapsing it.
export const timelineViewIdentity = (input = {}) => {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return null;
  }

  const view = { kind: 'timeline_view' };

  for (let index = 0; index < VIEW_FIELDS.length; index += 1) {
    const field = VIEW_FIELDS[index];
    const read = readIdentityString(input[field]);

    if (!read.ok) {
      return null;
    }

    view[field] = read.value;
  }

  return view;
};

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
  const sourceIdentity = timelineSourceIdentity(source.sourceTimelineId, source.conditions);
  const viewIdentity = timelineViewIdentity(view);

  if (!decoded.ok) {
    return decoded;
  }

  if (!sourceIdentity || !viewIdentity) {
    return { ok: false, reason: TIMELINE_ANCHOR_REASONS.INVALID };
  }

  return {
    ok: true,
    position: {
      version: TIMELINE_ANCHOR_VERSION,
      source: sourceIdentity,
      view: viewIdentity,
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
