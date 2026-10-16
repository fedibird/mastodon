import api from '../api';
import { isStatusId } from '../utils/filter_rules';

export const FILTER_MATCHES_REQUEST = 'FILTER_MATCHES_REQUEST';
export const FILTER_MATCHES_SUCCESS = 'FILTER_MATCHES_SUCCESS';
export const FILTER_MATCHES_FAIL = 'FILTER_MATCHES_FAIL';
export const FILTER_MATCHES_CLEAR = 'FILTER_MATCHES_CLEAR';

const validateResponse = (data, ids) => {
  if (!data || typeof data.matches !== 'object' || data.matches === null || Array.isArray(data.matches) || !Array.isArray(data.unavailable)) return false;
  const keys = Object.keys(data.matches);
  const unavailable = data.unavailable;
  const returned = [...keys, ...unavailable];
  return returned.length === ids.length && new Set(returned).size === ids.length && returned.every(id => ids.includes(id)) && keys.every(id => Array.isArray(data.matches[id]) && data.matches[id].every(isStatusId));
};

// P2 deliberately accepts IDs from its caller: no timeline traversal, batching,
// automatic retries, or status imports. Invalid/oversized inputs fail in full.
export const reconcileFilterMatches = (statusIds, { timeout } = {}) => async (dispatch, getState) => {
  if (!Array.isArray(statusIds) || statusIds.length > 100 || !statusIds.every(isStatusId)) throw new TypeError('Expected at most 100 decimal status ID strings');
  const ids = Array.from(new Set(statusIds));
  if (ids.length === 0) return;
  if (!getState().getIn(['filterMatches', 'baseline'])) throw new Error('Fetch complete filter definitions before reconciling matches');

  const generation = getState().getIn(['filterMatches', 'generation'], 0);
  const requestId = getState().getIn(['filterMatches', 'serial'], 0) + 1;
  const request = { generation, requestId, ids, skipLoading: true, skipAlert: true };
  dispatch({ ...request, type: FILTER_MATCHES_REQUEST });

  try {
    const client = api(getState);
    const body = { status_ids: ids };
    const { data } = await (timeout ? client.post('/api/v1/fedibird/filters/matches', body, { timeout }) : client.post('/api/v1/fedibird/filters/matches', body));
    if (!validateResponse(data, ids)) throw new TypeError('Invalid filter match response');
    dispatch({ ...request, type: FILTER_MATCHES_SUCCESS, matches: data.matches, unavailable: data.unavailable });
  } catch (error) {
    const status = error.response?.status;
    const retryAfter = error.response?.headers?.['retry-after'];
    let retryAt;
    if (retryAfter) retryAt = Number.isFinite(Number(retryAfter)) ? Date.now() + Number(retryAfter) * 1000 : Date.parse(retryAfter);
    dispatch({ ...request, type: FILTER_MATCHES_FAIL, status, retryAt });
  }
};

// P3 may release IDs it no longer needs. With no argument, clear all entries.
export const clearFilterMatches = ids => ({ type: FILTER_MATCHES_CLEAR, ids });
