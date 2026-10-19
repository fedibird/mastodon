import {
  TIMELINE_ANCHOR_REASONS,
  TIMELINE_ANCHOR_VERSION,
  decodeTimelineAnchor,
  displayRowAnchorIds,
  isDecimalStatusId,
  isDisplayRowId,
  isScrollHostKind,
  selectAnchorFromMeasurements,
  timelineAnchorDelta,
} from './anchor';

const failure = (reason) => ({ ok: false, reason });

const finite = (value) => typeof value === 'number' && Number.isFinite(value);

export const readDocumentVisibleTop = () => {
  if (typeof document === 'undefined') {
    return 0;
  }

  const portal = document.getElementById('tabs-bar__portal');
  const wrapper = portal && portal.closest('.tabs-bar__wrapper');

  if (!wrapper) {
    return 0;
  }

  const rect = wrapper.getBoundingClientRect();

  if (rect.bottom <= 0 || rect.top > 0) {
    return 0;
  }

  return Math.max(0, rect.bottom);
};

const hostScroller = (scrollHost) => {
  if (!scrollHost) {
    return null;
  }

  if (scrollHost.kind === 'document') {
    return scrollHost.scroller || (typeof document !== 'undefined' ? (document.scrollingElement || document.body) : null);
  }

  return scrollHost.scroller || scrollHost.list || null;
};

const ensureHost = (scrollHost) => {
  if (!scrollHost || !isScrollHostKind(scrollHost.kind)) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  const list = scrollHost.list;
  const scroller = hostScroller(scrollHost);

  if (!list || !scroller || typeof list.querySelector !== 'function') {
    return failure(TIMELINE_ANCHOR_REASONS.MISSING_HOST);
  }

  return { ok: true, list, scroller };
};

export const readScrollHostViewport = (scrollHost, visibleTop) => {
  const scroller = hostScroller(scrollHost);
  const rect = scroller && typeof scroller.getBoundingClientRect === 'function'
    ? scroller.getBoundingClientRect()
    : { top: 0, height: 0 };
  let top = visibleTop;

  if (!finite(top)) {
    top = scrollHost && scrollHost.kind === 'document' ? readDocumentVisibleTop() : (rect.top || 0);
  }

  let visibleHeight = 0;

  if (scrollHost && scrollHost.kind === 'document') {
    const windowHeight = typeof window !== 'undefined' && finite(window.innerHeight) ? window.innerHeight : 0;

    visibleHeight = Math.max(0, windowHeight - top);
  } else if (finite(rect.height) && rect.height > 0) {
    visibleHeight = rect.height;
  } else if (scroller && finite(scroller.clientHeight)) {
    visibleHeight = Math.max(0, scroller.clientHeight);
  }

  return { visibleTop: top, visibleHeight };
};

const articleSelector = (rowId) => {
  const value = String(rowId).replace(/\\/g, '\\\\').replace(/"/g, '\\"');

  return `article[data-id="${value}"]`;
};

const rowIdIncludes = (loadedStatusIds, rowId) => {
  if (!loadedStatusIds) {
    return null;
  }

  if (typeof loadedStatusIds.has === 'function' && !Array.isArray(loadedStatusIds)) {
    return loadedStatusIds.has(rowId);
  }

  if (typeof loadedStatusIds.indexOf === 'function') {
    return loadedStatusIds.indexOf(rowId) !== -1;
  }

  return false;
};

// One host only. Callers pass the list element; this never walks document.
export const findLoadedTimelineStatus = ({ scrollHost, statusId, loadedStatusIds } = {}) => {
  if (!isDecimalStatusId(statusId) && !isDisplayRowId(statusId)) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  const host = ensureHost(scrollHost);

  if (!host.ok) {
    return host;
  }

  const row = host.list.querySelector(articleSelector(statusId));

  if (row) {
    return {
      ok: true,
      statusId: row.getAttribute('data-id'),
      row,
    };
  }

  if (rowIdIncludes(loadedStatusIds, statusId) === false) {
    return failure(TIMELINE_ANCHOR_REASONS.NOT_LOADED);
  }

  if (!host.list.querySelector('article[data-id]')) {
    return failure(TIMELINE_ANCHOR_REASONS.EMPTY);
  }

  return failure(TIMELINE_ANCHOR_REASONS.NOT_FOUND);
};

const readFallbackScrollTop = (scroller) => (
  scroller && finite(scroller.scrollTop) ? scroller.scrollTop : 0
);

const measureUntilEdge = (list, edge) => {
  const articles = list.querySelectorAll('article[data-id]');
  const rows = [];

  for (let i = 0; i < articles.length; i += 1) {
    const rect = articles[i].getBoundingClientRect();
    const rowId = articles[i].getAttribute('data-id');

    rows.push({
      rowId: rowId || '',
      top: rect.top,
      bottom: rect.bottom,
      height: rect.height,
    });

    if (rect.bottom > edge) {
      break;
    }
  }

  return { count: articles.length, rows };
};

export const captureTimelineAnchor = ({ scrollHost, visibleTop, alignment = 'top', capturedAt } = {}) => {
  const align = alignment === 'center' ? 'center' : 'top';
  const host = ensureHost(scrollHost);
  const empty = {
    version: TIMELINE_ANCHOR_VERSION,
    statusId: null,
    displayRowId: null,
    offsetPx: 0,
    alignment: align,
  };

  if (!host.ok) {
    return empty;
  }

  const viewport = readScrollHostViewport(scrollHost, visibleTop);
  const edge = align === 'center' ? viewport.visibleTop + (viewport.visibleHeight / 2) : viewport.visibleTop;
  const measured = measureUntilEdge(host.list, edge);
  const selected = selectAnchorFromMeasurements({
    rows: measured.rows,
    visibleTop: viewport.visibleTop,
    visibleHeight: viewport.visibleHeight,
    alignment: align,
  });
  const rowIds = displayRowAnchorIds(selected.rowId);
  const anchor = {
    version: TIMELINE_ANCHOR_VERSION,
    statusId: rowIds ? rowIds.statusId : null,
    displayRowId: rowIds ? rowIds.displayRowId : null,
    offsetPx: rowIds && rowIds.displayRowId ? selected.offsetPx : 0,
    alignment: selected.alignment,
    fallbackScrollTop: readFallbackScrollTop(host.scroller),
  };

  if (typeof capturedAt === 'string' && !Number.isNaN(Date.parse(capturedAt))) {
    anchor.capturedAt = capturedAt;
  }

  return anchor;
};

const applyAbsoluteFallback = (scroller, fallbackScrollTop) => {
  if (!scroller || !finite(fallbackScrollTop)) {
    return false;
  }

  if (Math.abs(scroller.scrollTop - fallbackScrollTop) <= 0.5) {
    return true;
  }

  scroller.scrollTop = fallbackScrollTop;

  return true;
};

const applyDocumentDeltaFallback = (scrollHost, visibleTop, fallbackScrollTop) => {
  if (!scrollHost.list || !scrollHost.scroller || !finite(fallbackScrollTop) || !finite(visibleTop)) {
    return false;
  }

  const listOffset = visibleTop - scrollHost.list.getBoundingClientRect().top;
  const delta = fallbackScrollTop - listOffset;

  if (Math.abs(delta) <= 0.5) {
    return true;
  }

  scrollHost.scroller.scrollTop += delta;

  return true;
};

const withFallback = (result, { scrollHost, visibleTop, fallback, fallbackScrollTop }) => {
  if (fallback !== 'absolute' && fallback !== 'document-delta') {
    return result;
  }

  const applied = fallback === 'absolute'
    ? applyAbsoluteFallback(scrollHost.scroller, fallbackScrollTop)
    : applyDocumentDeltaFallback(scrollHost, visibleTop, fallbackScrollTop);

  if (!applied) {
    return result;
  }

  return { ...result, usedFallback: true };
};

// Align one already-rendered display row inside the given host.
// fallback is off unless the caller is inside the same mount and layout
// (the legacy split transition). A missing row never jumps to the top.
export const alignDisplayRow = ({
  scrollHost,
  visibleTop,
  rowId,
  offsetPx,
  alignment = 'top',
  fallback = 'none',
  fallbackScrollTop,
  loadedStatusIds,
} = {}) => {
  const host = ensureHost(scrollHost);

  if (!host.ok) {
    return host;
  }

  if (alignment !== 'top' && alignment !== 'center') {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  if (!finite(offsetPx)) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  const viewport = readScrollHostViewport({ ...scrollHost, scroller: host.scroller }, visibleTop);

  if (rowId === null || rowId === undefined || rowId === '') {
    return withFallback(failure(TIMELINE_ANCHOR_REASONS.EMPTY), {
      scrollHost: { ...scrollHost, scroller: host.scroller },
      visibleTop: viewport.visibleTop,
      fallback,
      fallbackScrollTop,
    });
  }

  if (!isDisplayRowId(rowId)) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  const found = findLoadedTimelineStatus({
    scrollHost: { ...scrollHost, list: host.list, scroller: host.scroller },
    statusId: rowId,
    loadedStatusIds,
  });

  if (!found.ok) {
    return withFallback(found, {
      scrollHost: { ...scrollHost, scroller: host.scroller },
      visibleTop: viewport.visibleTop,
      fallback,
      fallbackScrollTop,
    });
  }

  const rect = found.row.getBoundingClientRect();
  const delta = timelineAnchorDelta({
    rowTop: rect.top,
    rowHeight: rect.height,
    visibleTop: viewport.visibleTop,
    visibleHeight: viewport.visibleHeight,
    offsetPx,
    alignment,
  });

  if (!finite(delta)) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  if (Math.abs(delta) > 0.5) {
    host.scroller.scrollTop += delta;
  }

  const rowIds = displayRowAnchorIds(found.statusId);

  return {
    ok: true,
    anchor: {
      version: TIMELINE_ANCHOR_VERSION,
      statusId: rowIds ? rowIds.statusId : null,
      displayRowId: rowIds ? rowIds.displayRowId : found.statusId,
      offsetPx,
      alignment,
    },
  };
};

export const restoreTimelineAnchor = ({ scrollHost, visibleTop, anchor, fallback = 'none', loadedStatusIds } = {}) => {
  const decoded = decodeTimelineAnchor(anchor);

  if (!decoded.ok) {
    return decoded;
  }

  return alignDisplayRow({
    scrollHost,
    visibleTop,
    rowId: decoded.anchor.displayRowId || decoded.anchor.statusId,
    offsetPx: decoded.anchor.offsetPx,
    alignment: decoded.anchor.alignment,
    fallback,
    fallbackScrollTop: decoded.anchor.fallbackScrollTop,
    loadedStatusIds,
  });
};

export const scrollToLoadedTimelineStatus = ({
  scrollHost,
  visibleTop,
  statusId,
  displayRowId,
  alignment = 'top',
  offsetPx = 0,
  loadedStatusIds,
} = {}) => {
  const rowIds = displayRowId ? displayRowAnchorIds(displayRowId) : null;

  if (displayRowId && !rowIds) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  if (statusId !== undefined && statusId !== null && !isDecimalStatusId(statusId)) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  if (rowIds && statusId && rowIds.statusId !== statusId) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  const rowId = rowIds ? rowIds.displayRowId : statusId;

  if (!isDecimalStatusId(rowId) && !isDisplayRowId(rowId)) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  return alignDisplayRow({
    scrollHost,
    visibleTop,
    rowId,
    offsetPx,
    alignment,
    fallback: 'none',
    loadedStatusIds,
  });
};

// One or two correction frames. Cancel on unmount, a newer jump, or any
// caller-supplied abort (location change, user scroll). No observer loop.
export const scheduleTimelineAnchorFrames = ({ frames = 2, apply, shouldAbort } = {}) => {
  let cancelled = false;
  let frameId = 0;
  let remaining = frames;

  const tick = () => {
    if (cancelled || remaining <= 0 || typeof requestAnimationFrame !== 'function') {
      return;
    }

    remaining -= 1;
    frameId = requestAnimationFrame(() => {
      frameId = 0;

      if (cancelled) {
        return;
      }

      if (shouldAbort && shouldAbort()) {
        return;
      }

      if (typeof apply === 'function') {
        apply();
      }

      tick();
    });
  };

  tick();

  return () => {
    cancelled = true;

    if (frameId && typeof cancelAnimationFrame === 'function') {
      cancelAnimationFrame(frameId);
      frameId = 0;
    }
  };
};

export const legacySplitAnchorFromCapture = (captured, { fallbackOffset, target }) => ({
  id: captured && captured.displayRowId ? captured.displayRowId : null,
  offset: captured && captured.displayRowId ? captured.offsetPx : 0,
  fallbackOffset,
  target,
});

export const alignLegacySplitAnchor = ({ scrollHost, visibleTop, anchor, fallback }) => {
  if (!anchor) {
    return failure(TIMELINE_ANCHOR_REASONS.INVALID);
  }

  const rowId = anchor.id === null || anchor.id === undefined || anchor.id === '' ? null : anchor.id;

  return alignDisplayRow({
    scrollHost,
    visibleTop,
    rowId,
    offsetPx: finite(anchor.offset) ? anchor.offset : 0,
    alignment: 'top',
    fallback,
    fallbackScrollTop: anchor.fallbackOffset,
  });
};
