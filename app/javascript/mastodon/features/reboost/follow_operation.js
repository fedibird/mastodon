export const REBOOST_POLL_INTERVAL_MS = 2000;
export const REBOOST_POLL_LIMIT = 8;

const TERMINAL_STATES = ['completed', 'failed', 'cancelled'];

const delay = (ms) => new Promise((resolve) => {
  setTimeout(resolve, ms);
});

// Poll one operation. Stop at a terminal state, or after the attempt limit
// while it is still open. The caller keeps that open state on screen.
export function followReboostOperation ({ get, statusId, operationId, onUpdate, wait = delay }) {
  const config = operationId ? { params: { operation_id: operationId } } : undefined;

  return (async () => {
    for (let attempt = 0; attempt < REBOOST_POLL_LIMIT; attempt += 1) {
      await wait(REBOOST_POLL_INTERVAL_MS);

      const response = await get(`/api/v1/statuses/${statusId}/reboost_operation`, config);
      const operation = response.data || {};

      if (operationId && operation.id && String(operation.id) !== String(operationId)) {
        continue;
      }

      if (onUpdate) {
        onUpdate(operation);
      }

      if (TERMINAL_STATES.includes(operation.state)) {
        return operation;
      }
    }

    return null;
  })();
}
