import api from '../api';
import { isStaleRevalidationPoll, revalidationRequestId, revalidationResponseAccepted } from '../posting_context/revalidation_response';
import { fetchPostingContext } from './posting_contexts';

export const POSTING_CONTEXT_REVALIDATION_UPDATE = 'POSTING_CONTEXT_REVALIDATION_UPDATE';
export const POSTING_CONTEXT_REVALIDATION_FAIL = 'POSTING_CONTEXT_REVALIDATION_FAIL';

export const REVALIDATION_POLL_INTERVAL = 2000;
export const REVALIDATION_MAX_POLLS = 15;

const watchers = new Map();
const statusWatches = new Map();
const ACTIVE = {
  queued: true,
  running: true,
};

const terminal = state => state === 'completed' || state === 'partial' || state === 'failed';

const endpoint = accountId => (
  `/api/v1/fedibird/accounts/${encodeURIComponent(accountId)}/posting_context/revalidation`
);

const updateRevalidation = (accountId, data, { explicit = true, error = null, polling = 'idle', fromPoll = false, statusRead = false } = {}) => ({
  type: POSTING_CONTEXT_REVALIDATION_UPDATE,
  accountId: String(accountId),
  data,
  explicit,
  error,
  polling,
  fromPoll,
  statusRead,
  skipLoading: true,
  skipAlert: true,
});

const markPolling = (accountId, polling) => ({
  type: POSTING_CONTEXT_REVALIDATION_UPDATE,
  accountId: String(accountId),
  pollingOnly: true,
  polling,
  explicit: true,
  skipLoading: true,
  skipAlert: true,
});

const failRevalidation = (accountId, error) => ({
  type: POSTING_CONTEXT_REVALIDATION_FAIL,
  accountId: String(accountId),
  error,
  skipLoading: true,
  skipAlert: true,
});

const stopTimer = accountId => {
  const watcher = watchers.get(String(accountId));

  if (!watcher || !watcher.timer) {
    return;
  }

  clearInterval(watcher.timer);
  watcher.timer = null;
};

const pollIsCurrent = (accountId, generation) => {
  const watcher = watchers.get(String(accountId));

  return Boolean(watcher && watcher.generation === generation);
};

const finishJob = (dispatch, accountId, data) => {
  stopTimer(accountId);

  if (data.state === 'completed' || data.state === 'partial') {
    dispatch(fetchPostingContext(accountId, { force: true }));
  }
};

const revalidationRecord = (getState, accountId) => (
  getState().getIn(['posting_context_revalidations', String(accountId)])
);

const captureStatusWatch = (getState, accountId) => {
  const key = String(accountId);
  const current = revalidationRecord(getState, key);
  const requestId = (current && current.get('requestId')) || null;

  if (!statusWatches.has(key)) {
    statusWatches.set(key, { generation: 0, requestId });
  }

  return {
    generation: statusWatches.get(key).generation,
    requestId,
  };
};

const replaceWatchedRequest = (accountId, requestId) => {
  if (!requestId) {
    return;
  }

  const key = String(accountId);
  const watch = statusWatches.get(key) || { generation: 0, requestId: null };

  if (watch.requestId === requestId) {
    return;
  }

  statusWatches.set(key, { generation: watch.generation + 1, requestId });
};

const statusReadApplies = (getState, accountId, data, snapshot) => {
  const watch = statusWatches.get(String(accountId));
  const current = revalidationRecord(getState, accountId);
  const currentRequestId = current && current.get('requestId');
  const responseId = revalidationRequestId(data);
  const generationChanged = !watch || snapshot.generation !== watch.generation;
  const requestChanged = Boolean(snapshot.requestId && currentRequestId && snapshot.requestId !== currentRequestId);

  if ((generationChanged || requestChanged) && responseId !== currentRequestId) {
    return false;
  }

  if (!data || !current) {
    return !(generationChanged || requestChanged);
  }

  return !isStaleRevalidationPoll(current, { statusRead: true, data });
};

// Reducer and this check share isStaleRevalidationPoll. A terminal response
// that was not stored as the current job must not stop the newer poll.
const acceptedTerminal = (getState, accountId, data, { fromPoll = false, statusRead = false, generationIsCurrent = true } = {}) => {
  if (!data || !terminal(data.state)) {
    return false;
  }

  const current = revalidationRecord(getState, accountId);

  return revalidationResponseAccepted(current, data, {
    fromPoll,
    statusRead,
    generationIsCurrent,
  });
};

const pollingFor = data => (
  data && (data.state === 'queued' || data.state === 'running') ? 'active' : 'idle'
);

export function fetchPostingContextRevalidationStatus(accountId, { fromPoll = false, generation = null } = {}) {
  return (dispatch, getState) => {
    const snapshot = captureStatusWatch(getState, accountId);

    return api(getState).get(endpoint(accountId)).then(({ data }) => {
      const generationIsCurrent = !fromPoll || pollIsCurrent(accountId, generation);

      if (fromPoll && !generationIsCurrent) {
        return data;
      }

      if (!statusReadApplies(getState, accountId, data, snapshot)) {
        return data;
      }

      dispatch(updateRevalidation(accountId, data, {
        polling: pollingFor(data),
        fromPoll,
        statusRead: true,
      }));

      if (acceptedTerminal(getState, accountId, data, { fromPoll, statusRead: true, generationIsCurrent })) {
        finishJob(dispatch, accountId, data);
      }

      return data;
    }).catch(() => {
      if (fromPoll && !pollIsCurrent(accountId, generation)) {
        return null;
      }

      if (!statusReadApplies(getState, accountId, null, snapshot)) {
        return null;
      }

      dispatch(markPolling(accountId, 'interrupted'));
      stopTimer(accountId);
      return null;
    });
  };
}

const poll = (accountId) => {
  const key = String(accountId);
  const watcher = watchers.get(key);

  if (!watcher || watcher.inFlight) {
    return;
  }

  if (watcher.attempts >= REVALIDATION_MAX_POLLS) {
    stopTimer(key);
    watcher.dispatch(markPolling(key, 'timed_out'));
    return;
  }

  watcher.attempts += 1;
  watcher.inFlight = true;
  const generation = watcher.generation;

  Promise.resolve(watcher.dispatch(fetchPostingContextRevalidationStatus(key, {
    fromPoll: true,
    generation,
  }))).finally(() => {
    const current = watchers.get(key);

    if (current && current.generation === generation) {
      current.inFlight = false;
    }
  }).catch(() => {});
};

export function watchPostingContextRevalidation(accountId) {
  return (dispatch) => {
    const key = String(accountId);
    let watcher = watchers.get(key);

    if (!watcher) {
      watcher = {
        subscribers: 0,
        attempts: 0,
        generation: 1,
        inFlight: false,
        timer: null,
        dispatch,
      };
      watchers.set(key, watcher);
    }

    watcher.dispatch = dispatch;
    watcher.subscribers += 1;

    if (!watcher.timer) {
      watcher.timer = setInterval(() => poll(key), REVALIDATION_POLL_INTERVAL);
    }

    return () => {
      const current = watchers.get(key);

      if (!current) {
        return;
      }

      current.subscribers -= 1;

      if (current.subscribers <= 0) {
        stopTimer(key);
        current.generation += 1;
        watchers.delete(key);
      }
    };
  };
}

export function requestPostingContextRevalidation(accountId) {
  return (dispatch, getState) => api(getState).post(endpoint(accountId)).then(({ data }) => {
    replaceWatchedRequest(accountId, revalidationRequestId(data));
    dispatch(updateRevalidation(accountId, data, { polling: pollingFor(data) }));

    if (acceptedTerminal(getState, accountId, data)) {
      finishJob(dispatch, accountId, data);
    }

    return data;
  }).catch(error => {
    const status = error && error.response && error.response.status;

    if (status !== 429) {
      dispatch(failRevalidation(accountId, 'failed'));
      return null;
    }

    // A cooldown or host limit must not start another revalidation.
    return dispatch(fetchPostingContextRevalidationStatus(accountId)).then(data => {
      if (!data || data.state === 'idle') {
        dispatch(failRevalidation(accountId, 'rate_limited'));
      }

      return data;
    });
  });
}

export function revalidationIsActive(state) {
  return Boolean(ACTIVE[state]);
}
