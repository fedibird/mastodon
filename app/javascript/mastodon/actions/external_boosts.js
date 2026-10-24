import api from '../api';
import { importFetchedStatuses } from './importer';
import compareId from '../compare_id';
import { parseBoostEvent, revisionOfImmutable } from '../external_boosts/revision';

export const EXTERNAL_LINK_BOOST_CHANGED = 'EXTERNAL_LINK_BOOST_CHANGED';

// Held projections that carry a revision are read again on a reconnect and on
// a return to the tab. Each request is at most HELD_BOOST_BATCH ids, a run
// sends at most HELD_BOOST_BATCHES_PER_RUN requests, and runs are at least
// HELD_BOOST_MIN_GAP_MS apart. What is left over continues on a timer, so
// every held projection is read within a bounded number of runs, whatever
// its id.
export const HELD_BOOST_BATCH = 20;
export const HELD_BOOST_BATCHES_PER_RUN = 3;
export const HELD_BOOST_MIN_GAP_MS = 10000;
// After a failed request the next run waits GAP, 2 x GAP, 4 x GAP, ... up to
// HELD_BOOST_MAX_BACKOFF_MS, and the page gives up after HELD_BOOST_MAX_FAILURES
// failures in a row. The next reconnect or return to the tab starts again.
// 401 and 403 stop the run at once: the session needs to sign in again, and
// repeating the request cannot help.
export const HELD_BOOST_MAX_BACKOFF_MS = 160000;
export const HELD_BOOST_MAX_FAILURES = 6;

// `generation` moves on every reconnect and return to the tab. `verified`
// remembers, per held id, the generation whose response already covered it.
// An id is due while its generation is behind. Order is stalest generation
// first (never read before the others), then newest id, so a storm of
// reconnects cannot keep reading the same ids. Entries of statuses that are
// no longer held are dropped on every run, so the map is bounded by what the
// page holds. It lives with the page: a different login loads a new page.
let generation = 0;
const verified = new Map();
let lastRunAt = 0;
let running = false;
let timer = null;
let failures = 0;
let epoch = 0;

/**
 * The share state of a projection changed in another session. The payload is
 * ids and a pair only. A status that is not held is not stored: the next REST
 * payload of it carries the same pair, and a bounded floor protects an import
 * that is already in flight.
 *
 * @param {string|object} payload
 */
export function receiveExternalLinkBoostChanged(payload) {
  return (dispatch) => {
    let parsed = payload;

    if (typeof payload === 'string') {
      try {
        parsed = JSON.parse(payload);
      } catch (error) {
        return;
      }
    }

    const event = parseBoostEvent(parsed);

    if (!event) {
      return;
    }

    dispatch({
      type: EXTERNAL_LINK_BOOST_CHANGED,
      statusId: event.statusId,
      reblogged: event.reblogged,
      revision: event.revision,
    });
  };
}

const heldProjectionIds = (statuses) => {
  const ids = [];

  statuses.forEach((status, id) => {
    if (revisionOfImmutable(status) !== null) {
      ids.push(id);
    }
  });

  return ids;
};

const dueBatch = (held) => {
  const present = new Set(held);

  Array.from(verified.keys()).forEach(id => {
    if (!present.has(id)) {
      verified.delete(id);
    }
  });

  return held
    .filter(id => (verified.has(id) ? verified.get(id) : -1) < generation)
    .sort((a, b) => {
      const order = (verified.has(a) ? verified.get(a) : -1) - (verified.has(b) ? verified.get(b) : -1);

      return order !== 0 ? order : compareId(b, a);
    })
    .slice(0, HELD_BOOST_BATCH);
};

const heldFrom = (getState) => {
  const statuses = getState().get('statuses');

  return statuses ? heldProjectionIds(statuses) : [];
};

const scheduleContinuation = (dispatch, delay) => {
  if (timer) {
    return;
  }

  const scheduledIn = epoch;

  timer = setTimeout(() => {
    timer = null;

    if (scheduledIn === epoch) {
      dispatch(reconcileHeldExternalBoosts({ force: true }));
    }
  }, delay);
};

const runReconcile = async (dispatch, getState) => {
  if (running) {
    return;
  }

  const runEpoch = epoch;

  running = true;
  lastRunAt = Date.now();

  let failure = null;

  try {
    for (let sent = 0; sent < HELD_BOOST_BATCHES_PER_RUN; sent += 1) {
      const ids = dueBatch(heldFrom(getState));

      if (ids.length === 0) {
        break;
      }

      const covered = generation;
      let response;

      try {
        response = await api(getState).get('/api/v1/statuses', { params: { id: ids } });
      } catch (error) {
        failure = error || new Error('request failed');
        break;
      }

      // Logout or a page switch reset the state while the request was out.
      if (runEpoch !== epoch) {
        return;
      }

      failures = 0;

      ids.forEach(id => verified.set(id, covered));

      if (response && Array.isArray(response.data) && response.data.length > 0) {
        dispatch(importFetchedStatuses(response.data));
      }
    }
  } finally {
    if (runEpoch === epoch) {
      running = false;
    }
  }

  if (runEpoch !== epoch) {
    return;
  }

  if (failure) {
    const status = failure.response && failure.response.status;

    if (status === 401 || status === 403) {
      return;
    }

    failures += 1;

    if (failures < HELD_BOOST_MAX_FAILURES) {
      scheduleContinuation(dispatch, Math.min(HELD_BOOST_MIN_GAP_MS * (2 ** (failures - 1)), HELD_BOOST_MAX_BACKOFF_MS));
    }

    return;
  }

  if (dueBatch(heldFrom(getState)).length > 0) {
    scheduleContinuation(dispatch, HELD_BOOST_MIN_GAP_MS);
  }
};

/**
 * Re-reads the held projections of the signed-in user. A stream event that
 * was lost, or a state changed while this tab was away, is repaired here.
 * `begin` marks a reconnect or a return to the tab: every held id is due
 * again. `force` skips the minimum gap (a reconnect, or the continuation
 * timer). A call inside the gap is not dropped: it is deferred. A response
 * older than what the page already applied cannot roll the state back: the
 * reducer orders by revision.
 */
export function reconcileHeldExternalBoosts(options = {}) {
  return (dispatch, getState) => {
    if (options.begin) {
      generation += 1;
      failures = 0;

      // A reconnect does not wait for a long backoff timer.
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
    }

    const wait = options.force ? 0 : lastRunAt + HELD_BOOST_MIN_GAP_MS - Date.now();

    if (wait > 0) {
      if (dueBatch(heldFrom(getState)).length > 0) {
        scheduleContinuation(dispatch, wait);
      }

      return Promise.resolve();
    }

    return runReconcile(dispatch, getState);
  };
}

export function resetExternalBoostReconcile() {
  generation = 0;
  verified.clear();
  lastRunAt = 0;
  running = false;
  failures = 0;
  epoch += 1;

  if (timer) {
    clearTimeout(timer);
    timer = null;
  }
}

export const resetExternalBoostReconcileForTests = resetExternalBoostReconcile;
