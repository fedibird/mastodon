import compareId from '../compare_id';

export const RECONCILE_PAGE_LIMIT = 20;
export const RECONCILE_MAX_PAGES = 5;
export const RECONCILE_DELAYS_MS = [30000, 60000, 120000];
export const OVERLAY_MAX_AGE_MS = 5 * 60 * 1000;
export const CONFIRMED_OVERLAY_TTL_MS = 30000;

export function planOverlayWait (attempt, elapsedMs) {
  const remaining = OVERLAY_MAX_AGE_MS - elapsedMs;

  if (remaining <= 0) {
    return null;
  }

  const delay = RECONCILE_DELAYS_MS[attempt];

  if (delay === undefined || delay >= remaining) {
    return { mode: 'remove', delay: remaining };
  }

  return { mode: 'reconcile', delay };
}

const presentIds = (ids) => (ids || [])
  .filter(id => id !== null && id !== undefined)
  .map(id => String(id));

// Newest-first timeline page. Missing from the latest page is not exclusion:
// the id has to fall inside a fetched span, or the feed has to end without it.
// A newer id than everything already in the feed is still inconclusive.
export function classifyTimelinePage (statusId, ids, endOfFeed) {
  const target = String(statusId);
  const present = presentIds(ids);

  if (present.some(id => id === target)) {
    return 'confirmed';
  }

  if (present.length === 0) {
    return 'inconclusive';
  }

  const newest = present[0];
  const oldest = present[present.length - 1];

  if (compareId(target, newest) > 0) {
    return 'inconclusive';
  }

  if (compareId(target, oldest) >= 0) {
    return 'excluded';
  }

  if (endOfFeed) {
    return 'excluded';
  }

  return 'continue';
}

export function walkTimelineForStatus (statusId, pages, { limit = RECONCILE_PAGE_LIMIT, maxPages = RECONCILE_MAX_PAGES } = {}) {
  const visited = (pages || []).slice(0, maxPages);
  const target = String(statusId);
  let oldestSeen = null;
  let sawFullPage = false;

  for (let index = 0; index < visited.length; index += 1) {
    const page = visited[index];
    const ids = presentIds(page.ids);
    const statuses = page.statuses || [];

    if (ids.some(id => id === target)) {
      return {
        outcome: 'confirmed',
        status: statuses.find(status => status && String(status.id) === target) || null,
      };
    }

    if (ids.length === 0) {
      // A full page followed by an empty page has checked the older range.
      // The first page being empty is still inconclusive.
      if (sawFullPage && oldestSeen && compareId(target, oldestSeen) < 0) {
        return { outcome: 'excluded', status: null };
      }

      return { outcome: 'inconclusive', status: null };
    }

    const newest = ids[0];
    const oldest = ids[ids.length - 1];

    if (compareId(target, newest) > 0) {
      return { outcome: 'inconclusive', status: null };
    }

    if (compareId(target, oldest) >= 0) {
      return { outcome: 'excluded', status: null };
    }

    if (ids.length < limit) {
      return { outcome: 'excluded', status: null };
    }

    sawFullPage = true;
    oldestSeen = oldest;
  }

  return { outcome: 'continue', status: null };
}
