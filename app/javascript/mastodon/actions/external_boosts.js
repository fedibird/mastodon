import api from '../api';
import { importFetchedStatuses } from './importer';
import compareId from '../compare_id';
import { parseBoostEvent, revisionOfImmutable } from '../external_boosts/revision';

export const EXTERNAL_LINK_BOOST_CHANGED = 'EXTERNAL_LINK_BOOST_CHANGED';

// Held projections that carry a revision are read again on a reconnect and on
// a return to the tab. One request, a bounded number of ids, and a minimum
// gap between runs.
export const HELD_BOOST_BATCH = 20;
export const HELD_BOOST_MIN_GAP_MS = 10000;

let lastReconcileAt = 0;

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

  return ids.sort((a, b) => compareId(b, a)).slice(0, HELD_BOOST_BATCH);
};

/**
 * Re-reads the held projections of the signed-in user. A stream event that
 * was lost, or a state changed while this tab was away, is repaired here. A
 * response older than what the page already applied cannot roll the state
 * back: the reducer orders by revision.
 */
export function reconcileHeldExternalBoosts(options = {}) {
  return (dispatch, getState) => {
    const now = Date.now();

    if (!options.force && now - lastReconcileAt < HELD_BOOST_MIN_GAP_MS) {
      return Promise.resolve();
    }

    const statuses = getState().get('statuses');
    const ids = statuses ? heldProjectionIds(statuses) : [];

    if (ids.length === 0) {
      return Promise.resolve();
    }

    lastReconcileAt = now;

    return api(getState).get('/api/v1/statuses', { params: { id: ids } }).then(response => {
      if (response && Array.isArray(response.data) && response.data.length > 0) {
        dispatch(importFetchedStatuses(response.data));
      }
    }).catch(() => {});
  };
}

export function resetExternalBoostReconcileForTests() {
  lastReconcileAt = 0;
}
