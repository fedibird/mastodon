const TERMINAL = {
  completed: true,
  partial: true,
  failed: true,
};

const ACTIVE = {
  queued: true,
  running: true,
  idle: true,
};

export const revalidationRequestId = data => data && (data.request_id || data.requestId);

// Shared by the reducer and the poll action. A fromPoll response for another
// request, or an active response after a terminal one, is not the current job.
export const isStaleRevalidationPoll = (current, action) => {
  if (!action.fromPoll || !current) {
    return false;
  }

  const currentRequestId = current.get('requestId');
  const incomingRequestId = revalidationRequestId(action.data);

  if (currentRequestId && incomingRequestId && currentRequestId !== incomingRequestId) {
    return true;
  }

  return Boolean(TERMINAL[current.get('state')] && action.data && ACTIVE[action.data.state]);
};

// True only when this response is the job now stored for the account.
// generationIsCurrent is false after the watcher that issued the poll is gone.
export const revalidationResponseAccepted = (current, data, { fromPoll = false, generationIsCurrent = true } = {}) => {
  if (!current || !data || (fromPoll && !generationIsCurrent)) {
    return false;
  }

  if (isStaleRevalidationPoll(current, { fromPoll, data })) {
    return false;
  }

  const incomingRequestId = revalidationRequestId(data);

  if (incomingRequestId && current.get('requestId') !== incomingRequestId) {
    return false;
  }

  return current.get('state') === data.state;
};
