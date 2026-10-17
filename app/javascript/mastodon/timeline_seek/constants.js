// Seek queries name a source, not a column or scroll host. View identity stays
// on the split timeline id that owns the window.

export const TIMELINE_SEEK_VERSION = 1;

export const SEEK_KIND = Object.freeze({
  STATUS: 'status',
  DATE: 'date',
  ACCOUNT: 'account',
  SEARCH_HIT: 'searchHit',
  MEMBERSHIP: 'membership',
});

// P4b-1 contract for the next results UI. The server rejects more than
// MEMBERSHIP_ID_LIMIT ids per call. A search session stops at
// MEMBERSHIP_SESSION_CANDIDATE_LIMIT candidates (10 pages of the default
// search page, or 5 pages at the search API maximum).
export const MEMBERSHIP_ID_LIMIT = 50;
export const MEMBERSHIP_SESSION_CANDIDATE_LIMIT = 200;
export const MEMBERSHIP_SEARCH_PAGE_DEFAULT = 20;
export const MEMBERSHIP_SEARCH_PAGE_MAX = 40;

export const SEEK_OUTCOME = Object.freeze({
  RESOLVED: 'resolved',
  NOT_IN_SOURCE: 'not_in_source',
  NOT_VISIBLE: 'not_visible',
  NOT_FOUND: 'not_found',
  UNAVAILABLE: 'unavailable',
  UNSUPPORTED: 'unsupported',
  CANCELLED: 'cancelled',
  STALE: 'stale',
});

export const SEEK_CAPABILITY = Object.freeze({
  SUPPORTED: 'supported',
  APPROXIMATE: 'approximate',
  UNAVAILABLE: 'unavailable',
  UNSUPPORTED: 'unsupported',
});

export const SEEK_PREFERENCE = Object.freeze({
  NEAREST: 'nearest',
  BEFORE: 'before',
  AFTER: 'after',
});

export const WINDOW_SEEK_BEGIN = 'WINDOW_SEEK_BEGIN';
export const WINDOW_SEEK_FAIL = 'WINDOW_SEEK_FAIL';
export const WINDOW_SEEK_COMMIT = 'WINDOW_SEEK_COMMIT';
export const WINDOW_SEEK_SCROLL = 'WINDOW_SEEK_SCROLL';
export const WINDOW_SEEK_RESTORE = 'WINDOW_SEEK_RESTORE';

export const SEEK_PAGE_LIMIT = 40;

export const CLOSED_SOURCES = Object.freeze(['account', 'direct', 'notifications', 'mix']);
