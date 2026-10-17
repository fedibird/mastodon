// Session reading positions. Metadata only: no status bodies, pages, or tokens.

export const HISTORY_POSITION_MAX_ENTRIES = 32;
export const HISTORY_POSITION_TTL_MS = 30 * 60 * 1000;
export const HISTORY_POSITION_CAPTURE_INTERVAL_MS = 400;

export const HISTORY_RESUME_BEGIN = 'HISTORY_RESUME_BEGIN';
export const HISTORY_RESUME_SETTLE = 'HISTORY_RESUME_SETTLE';
export const HISTORY_RESUME_CANCEL = 'HISTORY_RESUME_CANCEL';

export const HISTORY_RESUME_IN_FLIGHT = Object.freeze([
  'restoring',
  'seek_pending',
  'scroll_pending',
]);

// P2 outcomes that must leave the current window and scroll position alone.
export const NON_DESTRUCTIVE_SEEK_OUTCOMES = Object.freeze([
  'unavailable',
  'unsupported',
  'not_visible',
  'not_found',
  'not_in_source',
]);
