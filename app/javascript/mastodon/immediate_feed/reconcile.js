import compareId from '../compare_id';

export const RECONCILE_PAGE_LIMIT = 20;
export const RECONCILE_MAX_PAGES = 5;

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

  for (let index = 0; index < visited.length; index += 1) {
    const page = visited[index];
    const ids = presentIds(page.ids);
    const reachedEnd = ids.length < limit;
    const outcome = classifyTimelinePage(statusId, ids, reachedEnd);

    if (outcome === 'confirmed') {
      return {
        outcome,
        status: page.statuses ? page.statuses.find(status => status && String(status.id) === String(statusId)) : null,
      };
    }

    if (outcome === 'excluded' || outcome === 'inconclusive') {
      return { outcome, status: null };
    }
  }

  return { outcome: 'continue', status: null };
}
