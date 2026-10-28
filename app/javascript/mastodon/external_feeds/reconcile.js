import compareId from '../compare_id';

export const MEMBERSHIP_BATCH = 50;
export const BODY_BATCH = 20;
export const BATCHES_PER_CYCLE = 4;
export const HISTORY_PAGES_PER_CYCLE = 2;

const REASONS = ['routes_updated', 'source_deleted', 'source_restored', 'list_removed', 'subscription_removed'];

const decimalId = (value) => {
  const text = String(value === undefined || value === null ? '' : value).trim();

  return /^\d+$/.test(text) ? text : null;
};

// The public control payload has no delivery envelope, route id, or generation.
// feed_routes_revision is not a dedupe key: the same revision can name another
// status, and an older revision is not proof that a row can be removed.
export const parseControl = (payload) => {
  let body = payload;

  if (typeof payload === 'string') {
    try {
      body = JSON.parse(payload);
    } catch (error) {
      return { ok: false, reason: 'invalid_json' };
    }
  }

  if (!body || body.version !== 1 || REASONS.indexOf(body.reason) === -1) {
    return { ok: false, reason: 'invalid_control' };
  }

  const targets = [];

  (Array.isArray(body.targets) ? body.targets : []).forEach(target => {
    if (!target || typeof target !== 'object') {
      return;
    }

    if (target.type === 'home') {
      targets.push({ type: 'home' });
      return;
    }

    const id = decimalId(target.id);

    if (target.type === 'list' && id) {
      targets.push({ type: 'list', id });
    }
  });

  if (!targets.length) {
    return { ok: false, reason: 'invalid_control' };
  }

  return {
    ok: true,
    reason: body.reason,
    targets,
    revision: body.feed_routes_revision === undefined || body.feed_routes_revision === null ? '' : String(body.feed_routes_revision),
    subscriptionId: body.subscription_id === undefined || body.subscription_id === null ? '' : String(body.subscription_id),
    statusId: decimalId(body.status_id),
  };
};

export const sameTarget = (left, right) => {
  if (!left || !right || left.type !== right.type) {
    return false;
  }

  if (left.type === 'home') {
    return true;
  }

  return left.id === right.id;
};

export const targetsOverlap = (viewTargets, eventTargets) => {
  const left = viewTargets || [];
  const right = eventTargets || [];

  return left.some(item => right.some(other => sameTarget(item, other)));
};

export const responsePreservesDisplayed = (status) => status !== 200;

export const chunkIds = (ids, size) => {
  const list = (ids || []).filter(id => decimalId(id));
  const width = size > 0 ? size : list.length;
  const chunks = [];

  for (let index = 0; index < list.length; index += width) {
    chunks.push(list.slice(index, index + width));
  }

  return chunks;
};

export const HISTORY_PAGE_SIZE = 40;

// The next slice of ids that this generation has not confirmed. Callers keep
// the per-request cap and the per-cycle batch budget; the checked set is how
// the following cycle reaches the tail.
export const budgetChunks = (ids, size, batches) => {
  const chunks = chunkIds(ids, size);
  const take = batches > 0 ? batches : 0;

  return {
    chunks: chunks.slice(0, take),
    remaining: chunks.length > take,
  };
};

// A row whose stream clock moved after the request is left untouched.
// feed_regenerating stays unconfirmed. Other unknown rows stay on screen.
// not_in_source, not_visible, and not_found leave this view only.
export const planMembership = ({ rows, movedSince }) => {
  const removeIds = [];
  const staleIds = [];
  const checkedIds = [];
  const moved = typeof movedSince === 'function' ? movedSince : () => false;

  (rows || []).forEach(row => {
    const id = decimalId(row && row.id);

    if (!id) {
      return;
    }

    if (moved(id)) {
      staleIds.push(id);
      return;
    }

    if (row.outcome === 'unknown' && row.reason === 'feed_regenerating') {
      staleIds.push(id);
      return;
    }

    if (row.outcome === 'not_in_source' || row.outcome === 'not_visible' || row.outcome === 'not_found') {
      removeIds.push(id);
    }

    if (row.outcome === 'member' || row.outcome === 'not_in_source' || row.outcome === 'not_visible' || row.outcome === 'not_found' || row.outcome === 'unknown' || row.outcome === 'invalid') {
      checkedIds.push(id);
    }
  });

  return { removeIds, staleIds, checkedIds };
};

export const loadedRanges = (items) => {
  const segments = segmentsOf(items);

  if (segments.length) {
    return segments.map(segment => ({
      key: segment[0],
      newest: segment[0],
      oldest: segment[segment.length - 1],
      ids: segment,
      empty: false,
      skip: false,
    }));
  }

  const hasGap = (items || []).some(id => id === null || id === undefined);

  return [{
    key: 'empty',
    newest: null,
    oldest: null,
    ids: [],
    empty: !hasGap,
    skip: hasGap,
  }];
};

// A full page that is still newer than the loaded edge continues. A short
// page, a 0/1 id range, and an empty range stop after the page that was asked.
export const nextHistoryCursor = (segment, statuses, pageSize) => {
  if (!segment || segment.empty || !segment.ids || segment.ids.length < 2) {
    return { done: true, cursor: null };
  }

  const page = statuses || [];

  if (page.length < pageSize) {
    return { done: true, cursor: null };
  }

  const oldestReturned = decimalId(page[page.length - 1] && page[page.length - 1].id);

  if (!oldestReturned || (segment.oldest && compareId(oldestReturned, segment.oldest) <= 0)) {
    return { done: true, cursor: null };
  }

  return { done: false, cursor: oldestReturned };
};

const segmentsOf = (items) => {
  const segments = [];
  let current = [];

  (items || []).forEach(id => {
    if (id === null || id === undefined) {
      if (current.length) {
        segments.push(current);
      }

      current = [];
      return;
    }

    current.push(String(id));
  });

  if (current.length) {
    segments.push(current);
  }

  return segments;
};

const insideSegment = (id, segment) => {
  if (!segment.length) {
    return false;
  }

  const newest = segment[0];
  const oldest = segment[segment.length - 1];

  return compareId(id, newest) < 0 && compareId(id, oldest) > 0;
};

// Insert ids that sit strictly inside a loaded contiguous run. Newer than the
// top and older than the loaded edge stay out, and a gap is not closed.
export const spliceHistory = (items, insertIds) => {
  const list = items || [];
  const segments = segmentsOf(list);
  const present = new Set(list.filter(id => id !== null && id !== undefined).map(id => String(id)));
  const inserted = [];

  (insertIds || []).forEach(value => {
    const id = decimalId(value);

    if (!id || present.has(id)) {
      return;
    }

    if (!segments.some(segment => insideSegment(id, segment))) {
      return;
    }

    present.add(id);
    inserted.push(id);
  });

  if (!inserted.length) {
    return { items: list.slice(), inserted };
  }

  const next = [];
  let segment = [];
  const flush = () => {
    if (!segment.length) {
      return;
    }

    const extra = inserted.filter(id => insideSegment(id, segment));

    extra.sort((left, right) => compareId(right, left));
    const merged = segment.concat(extra).sort((left, right) => compareId(right, left));

    merged.forEach(id => next.push(id));
    segment = [];
  };

  list.forEach(id => {
    if (id === null || id === undefined) {
      flush();
      next.push(null);
      return;
    }

    segment.push(String(id));
  });
  flush();

  return { items: next, inserted };
};

export const statusesInsideLoadedRange = (items, statuses) => {
  const ids = (statuses || []).map(status => status && status.id).filter(Boolean);
  const plan = spliceHistory(items, ids);
  const chosen = new Set(plan.inserted);

  return {
    inserted: plan.inserted,
    statuses: (statuses || []).filter(status => status && chosen.has(String(status.id))),
  };
};

// Interior ids stay inside a loaded run. An empty list can be seeded. A single
// loaded id can gain older neighbours below it. A null gap stays open.
export const placeReconcileIds = (items, insertIds, options = {}) => {
  const list = (items || []).slice();
  const hasId = list.some(id => id !== null && id !== undefined);
  const hasGap = list.some(id => id === null || id === undefined);

  if (!hasId && !hasGap && options.seed) {
    const ids = [];

    (insertIds || []).forEach(value => {
      const id = decimalId(value);

      if (id && ids.indexOf(id) === -1) {
        ids.push(id);
      }
    });
    ids.sort((left, right) => compareId(right, left));

    return { items: ids, inserted: ids.slice() };
  }

  const interior = spliceHistory(list, insertIds);
  const segments = segmentsOf(interior.items);
  const last = segments[segments.length - 1];

  if (!last || last.length !== 1) {
    return interior;
  }

  const anchor = last[0];
  const present = new Set(interior.items.filter(id => id !== null && id !== undefined).map(id => String(id)));
  const older = [];

  (insertIds || []).forEach(value => {
    const id = decimalId(value);

    if (!id || present.has(id) || older.indexOf(id) !== -1) {
      return;
    }

    if (compareId(id, anchor) < 0) {
      older.push(id);
      present.add(id);
    }
  });

  if (!older.length) {
    return interior;
  }

  older.sort((left, right) => compareId(right, left));
  let lastNonNull = -1;

  interior.items.forEach((id, index) => {
    if (id !== null && id !== undefined) {
      lastNonNull = index;
    }
  });

  if (lastNonNull < 0 || String(interior.items[lastNonNull]) !== anchor) {
    return interior;
  }

  const next = interior.items.slice(0, lastNonNull + 1).concat(older, interior.items.slice(lastNonNull + 1));

  return { items: next, inserted: interior.inserted.concat(older) };
};

const detachMovedBody = (status, movedSince) => {
  if (!status || typeof status !== 'object' || !status.id) {
    return status;
  }

  const copy = { ...status };

  ['reblog', 'quote'].forEach(field => {
    const nested = copy[field];

    if (!nested || typeof nested !== 'object' || !nested.id) {
      return;
    }

    if (movedSince(nested.id)) {
      copy[field] = String(nested.id);
    } else {
      copy[field] = detachMovedBody(nested, movedSince);
    }
  });

  return copy;
};

// Drop a body whose stream clock moved after the request, including a nested
// boost or quote. The parent keeps the id so the newer stored body stays.
export const isExternalStatus = (status) => {
  if (!status) {
    return false;
  }

  const read = (key) => (typeof status.get === 'function' ? status.get(key) : status[key]);
  const visibility = read('visibility_ex') || read('visibility');

  return visibility === 'external';
};

// Newest-first. A null gap stays where it is. The inserted id is a decimal
// string, so compareId never coerces a 64-bit snowflake through Number.
export const insertIdDescending = (ids, id) => {
  const value = decimalId(id);

  if (!value) {
    return (ids || []).slice();
  }

  const next = [];
  let placed = false;

  (ids || []).forEach(existing => {
    if (!placed && existing !== null && existing !== undefined && compareId(value, String(existing)) > 0) {
      next.push(value);
      placed = true;
    }

    next.push(existing);
  });

  if (!placed) {
    next.push(value);
  }

  return next;
};

export const protectStatusBodies = (statuses, movedSince) => (statuses || []).reduce((kept, status) => {
  if (!status || !status.id || movedSince(status.id)) {
    return kept;
  }

  kept.push(detachMovedBody(status, movedSince));
  return kept;
}, []);
