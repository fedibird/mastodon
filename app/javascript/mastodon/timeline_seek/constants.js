// Seek queries name a source, not a column or scroll host. View identity stays
// on the split timeline id that owns the window.

export const TIMELINE_SEEK_VERSION = 1;

export const SEEK_KIND = Object.freeze({
  STATUS: 'status',
  DATE: 'date',
  ACCOUNT: 'account',
  SEARCH_HIT: 'searchHit',
});

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

export const SEEK_PAGE_LIMIT = 40;

export const CLOSED_SOURCES = Object.freeze(['account', 'direct', 'notifications', 'mix']);
