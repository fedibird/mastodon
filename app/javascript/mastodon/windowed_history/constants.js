// History panes keep a bounded id list. The API page size is 20, so 240 ids
// is twelve pages: enough to fill a tall column and scroll without trimming
// on every small movement. 320 is the steady cap after a page is merged
// (240 plus four pages of slack). A response may pass 320 only while it is
// being merged, and trim brings it back before the next paint.
export const WINDOW_TARGET = 240;

export const WINDOW_HARD_CAP = 320;

export const WINDOW_PAGE_LIMIT = 20;

// Home, lists, and the limited home feed are Redis ZSETs trimmed to
// FeedManager::MAX_ITEMS (2000). Newer/older pages cannot see past that.
// Tag, public, domain, group, and personal timelines read Postgres in id
// order, so a short page is the real end of that query.
export const HISTORY_CAPABILITY = Object.freeze({
  REDIS: 'redis',
  DATABASE: 'database',
});

export const HISTORY_EDGE = Object.freeze({
  OPEN: 'open',
  LOADING: 'loading',
  ERROR: 'error',
  EXHAUSTED: 'exhausted',
  UNAVAILABLE: 'unavailable',
});
