import { isDecimalStatusId, isDisplayRowId } from '../timeline_navigation';
import {
  READING_BOOKMARK_LIMIT,
  readingBookmarkPayload,
  readingBookmarkTimelineId,
} from './contract';

const SEARCH_KEYS = ['q', 'query', 'text', 'raw', 'body', 'spoiler_text', 'content'];

const KNOWN_ERRORS = [
  'conflict',
  'limit',
  'duplicate_name',
  'invalid_name',
  'invalid_anchor',
  'invalid_context',
  'invalid_source',
  'source_not_found',
  'not_accessible',
  'source_mismatch',
  'remote_group',
  'search_or_content_not_accepted',
  'window_not_accepted',
];

const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

const containsKey = (value, keys) => {
  if (!value || typeof value !== 'object') {
    return false;
  }

  if (Array.isArray(value)) {
    return value.some(item => containsKey(item, keys));
  }

  return Object.keys(value).some(key => keys.indexOf(key) !== -1 || containsKey(value[key], keys));
};

const stable = (value) => {
  if (Array.isArray(value)) {
    return `[${value.map(stable).join(',')}]`;
  }

  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${key}:${stable(value[key])}`).join(',')}}`;
  }

  return JSON.stringify(value);
};

// Empty lists are omitted by the server. False flags stay, because public
// and personal timelines store them.
const compactContext = (context) => {
  const next = {};

  Object.keys(context || {}).forEach(key => {
    const value = context[key];

    if (Array.isArray(value) && value.length === 0) {
      return;
    }

    next[key] = value;
  });

  return next;
};

const anchorForCompare = (bookmark) => {
  const anchor = bookmark && bookmark.anchor ? bookmark.anchor : {};

  return {
    version: anchor.version || 1,
    statusId: isDecimalStatusId(anchor.statusId) ? anchor.statusId : '1',
    offsetPx: Number.isInteger(anchor.offsetPx) ? anchor.offsetPx : 0,
    alignment: anchor.alignment === 'center' ? 'center' : 'top',
    displayRowId: anchor.displayRowId || undefined,
  };
};

export const contractFromBookmark = (bookmark) => {
  const context = bookmark && bookmark.context && typeof bookmark.context === 'object' ? bookmark.context : {};
  const source = bookmark && bookmark.source;
  let path = '';

  if (source === 'list' && context.id) {
    path = `/api/v1/timelines/list/${context.id}`;
  } else if (source === 'group' && context.id) {
    path = `/api/v1/timelines/group/${context.id}`;
  } else if (source === 'hashtag' && context.hashtag) {
    path = `/api/v1/timelines/tag/${encodeURIComponent(context.hashtag)}`;
  }

  return {
    source,
    params: context,
    path,
  };
};

// The history surface is the only save source. A missing host, a null status,
// or a window/search payload is not a reading anchor.
export const readingAnchorFromSurface = (captured) => {
  if (!captured) {
    return { ok: false, reason: 'history_closed' };
  }

  if (containsKey(captured, SEARCH_KEYS) || own(captured, 'window') || own(captured, 'items') || own(captured, 'statuses')) {
    return { ok: false, reason: containsKey(captured, SEARCH_KEYS) ? 'search_or_content_not_accepted' : 'window_not_accepted' };
  }

  if (!isDecimalStatusId(captured.statusId)) {
    return { ok: false, reason: 'no_reading_anchor' };
  }

  if (captured.displayRowId && !isDisplayRowId(captured.displayRowId)) {
    return { ok: false, reason: 'no_reading_anchor' };
  }

  const anchor = {
    version: captured.version,
    statusId: captured.statusId,
    displayRowId: captured.displayRowId || undefined,
    offsetPx: captured.offsetPx,
    alignment: captured.alignment,
    capturedAt: captured.capturedAt,
  };
  const built = readingBookmarkPayload({
    name: 'place',
    contract: { source: 'home', params: {} },
    anchor,
  });

  if (!built.ok) {
    return { ok: false, reason: built.reason === 'invalid_anchor' ? 'no_reading_anchor' : built.reason };
  }

  const ready = {
    version: anchor.version,
    statusId: anchor.statusId,
    offsetPx: anchor.offsetPx,
    alignment: anchor.alignment,
  };

  if (anchor.displayRowId) {
    ready.displayRowId = anchor.displayRowId;
  }

  if (anchor.capturedAt) {
    ready.capturedAt = anchor.capturedAt;
  }

  return { ok: true, anchor: ready };
};

export const sameReadingPlace = (bookmark, contract) => {
  if (!bookmark || !contract || typeof bookmark.source !== 'string') {
    return false;
  }

  const built = readingBookmarkPayload({
    name: 'place',
    contract,
    anchor: anchorForCompare(bookmark),
  });

  if (!built.ok || built.payload.source !== bookmark.source) {
    return false;
  }

  const timelineId = bookmark.sourceTimelineId || readingBookmarkTimelineId(bookmark.source, bookmark.context);

  if (timelineId !== built.payload.source_timeline_id) {
    return false;
  }

  return stable(compactContext(built.payload.context)) === stable(compactContext(bookmark.context));
};

// Saved availability.membership is never permission to move. unchecked and a
// stale member both wait for a fresh membership call.
export const bookmarkColumnDecision = (bookmark, contract) => {
  if (!bookmark || !contract) {
    return { action: 'refuse', place: 'unavailable', reason: 'missing' };
  }

  const sourceState = bookmark.availability && bookmark.availability.source;

  if (sourceState === 'missing' || sourceState === 'not_accessible') {
    return { action: 'refuse', place: 'unavailable', reason: sourceState };
  }

  if (sourceState === 'uncertain') {
    return { action: 'refuse', place: 'uncertain', reason: 'uncertain' };
  }

  if (!sameReadingPlace(bookmark, contract)) {
    return { action: 'guide', place: 'different_source', reason: 'different_source' };
  }

  if (!bookmark.anchor || !isDecimalStatusId(bookmark.anchor.statusId)) {
    return { action: 'refuse', place: 'unavailable', reason: 'invalid_anchor' };
  }

  return { action: 'recheck', place: 'pending', reason: 'membership_unchecked' };
};

export const bookmarkPresentation = (bookmark) => {
  const availability = bookmark && bookmark.availability ? bookmark.availability : {};
  const sourceState = typeof availability.source === 'string' ? availability.source : 'uncertain';
  const label = sourceState === 'available' && typeof bookmark.sourceLabel === 'string' ? bookmark.sourceLabel : null;

  return {
    name: bookmark && typeof bookmark.name === 'string' ? bookmark.name : '',
    source: bookmark && bookmark.source,
    sourceLabel: label,
    sourceState,
    anchorState: typeof availability.anchor === 'string' ? availability.anchor : 'unchecked',
    membership: 'unchecked',
    capability: typeof availability.capability === 'string' ? availability.capability : null,
    limitations: Array.isArray(availability.limitations) ? availability.limitations.filter(item => typeof item === 'string') : [],
    updatedAt: bookmark && bookmark.updatedAt ? bookmark.updatedAt : null,
  };
};

export const bookmarksForScope = (rows, contract, scope) => {
  const list = Array.isArray(rows) ? rows : [];

  if (scope === 'all') {
    return list;
  }

  return list.filter(row => sameReadingPlace(row, contract));
};

export const bookmarkLimitReached = (rows) => Array.isArray(rows) && rows.length >= READING_BOOKMARK_LIMIT;

export const readingBookmarkFailure = (error) => {
  if (error && error.ok === false && typeof error.reason === 'string' && !error.response) {
    return { ok: false, reason: error.reason };
  }

  const status = error && error.response ? error.response.status : 0;
  const data = error && error.response ? error.response.data : null;
  const code = data && typeof data.error === 'string' ? data.error : '';

  if (status === 409 || code === 'conflict') {
    return { ok: false, reason: 'conflict', status: status || 409 };
  }

  if (KNOWN_ERRORS.indexOf(code) !== -1) {
    return { ok: false, reason: code, status };
  }

  return { ok: false, reason: 'network', status };
};
