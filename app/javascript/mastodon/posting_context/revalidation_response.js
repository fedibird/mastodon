const PROGRESS = {
  idle: 0,
  queued: 1,
  running: 2,
  completed: 3,
  partial: 3,
  failed: 3,
};

export const revalidationRequestId = data => data && (data.request_id || data.requestId);

const observesStatus = action => Boolean(action && (action.fromPoll || action.statusRead));

// Shared by the reducer and every status GET. A manual refresh uses the same
// request-id and progress checks as an automatic poll. A POST is not a status
// read, so it can switch the current job.
export const isStaleRevalidationPoll = (current, action) => {
  if (!observesStatus(action) || !current) {
    return false;
  }

  const currentRequestId = current.get('requestId');
  const incomingRequestId = revalidationRequestId(action.data);

  if (currentRequestId && incomingRequestId && currentRequestId !== incomingRequestId) {
    return true;
  }

  const currentProgress = PROGRESS[current.get('state')];
  const incomingProgress = action.data && PROGRESS[action.data.state];

  return currentProgress !== undefined && incomingProgress !== undefined && incomingProgress < currentProgress;
};

// True only when this response is the job now stored for the account.
// generationIsCurrent is the watcher generation captured before dispatch.
export const revalidationResponseAccepted = (current, data, { fromPoll = false, statusRead = false, generationIsCurrent = true } = {}) => {
  if (!current || !data || (fromPoll && !generationIsCurrent)) {
    return false;
  }

  if (isStaleRevalidationPoll(current, { fromPoll, statusRead, data })) {
    return false;
  }

  const incomingRequestId = revalidationRequestId(data);

  if ((fromPoll || statusRead) && incomingRequestId && current.get('requestId') !== incomingRequestId) {
    return false;
  }

  return current.get('state') === data.state;
};
