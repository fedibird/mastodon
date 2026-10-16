// Complete-definition transport stays independent of status/UI actions.
import api from '../api';
import { isStatusId } from '../utils/filter_rules';

export const FILTERS_FETCH_REQUEST = 'FILTERS_FETCH_REQUEST';
export const FILTERS_FETCH_SUCCESS = 'FILTERS_FETCH_SUCCESS';
export const FILTERS_FETCH_FAIL    = 'FILTERS_FETCH_FAIL';

// An earlier load/stream refresh must not overwrite a post-commit collection.
const latestFilterFetch = new WeakMap();

const streamRefreshes = new WeakMap();
const unknownRefreshes = new WeakMap();

export const UNKNOWN_FILTER_CACHE_LIMIT = 2000;
const UNKNOWN_FILTER_TTL = 60000;
const UNKNOWN_FILTER_INTERVAL = 5000;

// A FilterResult is only a hint to revalidate complete definitions. Negative
// results (including deleted IDs) and failures are suppressed per ID for one
// minute; distinct-ID storms get at most one trigger per five seconds/store.
// Timers are driven by incoming payloads, never an autonomous retry loop.
export const revalidateUnknownFilters = ids => (dispatch, getState) => {
  const state = getState();
  if (!state.getIn(['filterMatches', 'baseline'])) return;
  const unknown = ids.filter(id => isStatusId(id) && !state.getIn(['filters', id]));
  if (unknown.length === 0) return;

  let refresh = unknownRefreshes.get(dispatch);
  if (!refresh) {
    refresh = { seen: new Map(), pending: new Set(), timer: null, lastAttempt: -Infinity };
    unknownRefreshes.set(dispatch, refresh);
  }
  const now = Date.now();
  unknown.forEach(id => {
    if (refresh.seen.get(id) > now) return;
    refresh.seen.delete(id);
    refresh.seen.set(id, now + UNKNOWN_FILTER_TTL);
    refresh.pending.add(id);
    while (refresh.seen.size > UNKNOWN_FILTER_CACHE_LIMIT) {
      const oldest = refresh.seen.keys().next().value;
      refresh.seen.delete(oldest);
      refresh.pending.delete(oldest);
    }
  });
  if (refresh.pending.size === 0 || refresh.timer !== null) return;
  refresh.timer = setTimeout(() => {
    refresh.timer = null;
    const stillUnknown = Array.from(refresh.pending).some(id => !getState().getIn(['filters', id]));
    refresh.pending.clear();
    if (!stillUnknown) return;
    refresh.lastAttempt = Date.now();
    dispatch(scheduleFiltersRefresh());
  }, Math.max(0, refresh.lastAttempt + UNKNOWN_FILTER_INTERVAL - now));
};

// One timer and one in-flight stream refresh per store. Continuous events
// coalesce into a single trailing refresh; errors do not trigger retries.
export const scheduleFiltersRefresh = () => dispatch => {
  let refresh = streamRefreshes.get(dispatch);
  if (!refresh) {
    refresh = { dirty: false, timer: null, pending: false };
    streamRefreshes.set(dispatch, refresh);
  }
  refresh.dirty = true;
  const schedule = () => {
    if (refresh.timer !== null || refresh.pending) return;
    refresh.timer = setTimeout(async () => {
      refresh.timer = null;
      refresh.pending = true;
      refresh.dirty = false;
      try {
        await dispatch(fetchFilters());
      } finally {
        refresh.pending = false;
        if (refresh.dirty) schedule();
        else streamRefreshes.delete(dispatch);
      }
    }, 250);
  };
  schedule();
};

export const fetchFilters = () => (dispatch, getState) => {
  const request = {};
  latestFilterFetch.set(dispatch, request);
  dispatch({
    type: FILTERS_FETCH_REQUEST,
    skipLoading: true,
  });

  return api(getState)
    .get('/api/v2/filters')
    .then(({ data }) => {
      if (latestFilterFetch.get(dispatch) !== request) return;
      // FILTERS_FETCH_SUCCESS replaces the collection. A preceding
      // FILTERS_IMPORT merge would be overwritten on the next dispatch.
      dispatch({
        type: FILTERS_FETCH_SUCCESS,
        filters: data,
        receivedAt: Date.now(),
        skipLoading: true,
      });
    })
    .catch(err => {
      if (latestFilterFetch.get(dispatch) !== request) return;
      dispatch({ type: FILTERS_FETCH_FAIL, err, skipLoading: true, skipAlert: true });
    });
};
