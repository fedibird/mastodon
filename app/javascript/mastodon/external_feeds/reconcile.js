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

const epochOf = (map, id) => (map && Object.prototype.hasOwnProperty.call(map, id) ? map[id] : 0);

// A row whose stream generation moved is left untouched. unknown stays.
// not_in_source, not_visible, and not_found leave this view only.
export const planMembership = ({ rows, requestedEpochs, currentEpochs }) => {
  const removeIds = [];
  const staleIds = [];

  (rows || []).forEach(row => {
    const id = decimalId(row && row.id);

    if (!id) {
      return;
    }

    if (epochOf(currentEpochs, id) !== epochOf(requestedEpochs, id)) {
      staleIds.push(id);
      return;
    }

    if (row.outcome === 'not_in_source' || row.outcome === 'not_visible' || row.outcome === 'not_found') {
      removeIds.push(id);
    }
  });

  return { removeIds, staleIds };
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
