import api from '../api';
import { fetchPostingContext } from './posting_contexts';

export const POSTING_CONTEXT_REVALIDATION_UPDATE = 'POSTING_CONTEXT_REVALIDATION_UPDATE';
export const POSTING_CONTEXT_REVALIDATION_FAIL = 'POSTING_CONTEXT_REVALIDATION_FAIL';

export const REVALIDATION_POLL_INTERVAL = 2000;
export const REVALIDATION_MAX_POLLS = 15;

const watchers = new Map();
const ACTIVE = {
  queued: true,
  running: true,
};

const terminal = state => state === 'completed' || state === 'partial' || state === 'failed';

const endpoint = accountId => (
  `/api/v1/fedibird/accounts/${encodeURIComponent(accountId)}/posting_context/revalidation`
);

const updateRevalidation = (accountId, data, { explicit = true, error = null } = {}) => ({
  type: POSTING_CONTEXT_REVALIDATION_UPDATE,
  accountId: String(accountId),
  data,
  explicit,
  error,
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

const finishJob = (dispatch, accountId, data) => {
  stopTimer(accountId);

  if (data.state === 'completed' || data.state === 'partial') {
    dispatch(fetchPostingContext(accountId, { force: true }));
  }
};

export function fetchPostingContextRevalidationStatus(accountId) {
  return (dispatch, getState) => api(getState).get(endpoint(accountId)).then(({ data }) => {
    dispatch(updateRevalidation(accountId, data));

    if (terminal(data.state)) {
      finishJob(dispatch, accountId, data);
    }

    return data;
  }).catch(() => {
    dispatch(failRevalidation(accountId, 'status'));
    stopTimer(accountId);
  });
}

const poll = (accountId) => {
  const watcher = watchers.get(String(accountId));

  if (!watcher) {
    return;
  }

  watcher.attempts += 1;

  if (watcher.attempts > REVALIDATION_MAX_POLLS) {
    stopTimer(accountId);
    return;
  }

  watcher.dispatch(fetchPostingContextRevalidationStatus(accountId));
};

export function watchPostingContextRevalidation(accountId) {
  return (dispatch) => {
    const key = String(accountId);
    let watcher = watchers.get(key);

    if (!watcher) {
      watcher = { subscribers: 0, attempts: 0, timer: null, dispatch };
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
        watchers.delete(key);
      }
    };
  };
}

export function requestPostingContextRevalidation(accountId) {
  return (dispatch, getState) => api(getState).post(endpoint(accountId)).then(({ data }) => {
    dispatch(updateRevalidation(accountId, data));

    if (terminal(data.state)) {
      finishJob(dispatch, accountId, data);
    }

    return data;
  }).catch(error => {
    const status = error && error.response && error.response.status;

    if (status !== 429) {
      dispatch(failRevalidation(accountId, 'failed'));
      return null;
    }

    // Cooldown and host limits do not start another fetch. Read the stored
    // job so a finished revalidation can still refresh discovery.
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
