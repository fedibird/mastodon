import { followReboostOperation, REBOOST_POLL_INTERVAL_MS, REBOOST_POLL_LIMIT } from '../follow_operation';

const immediate = () => Promise.resolve();

describe('followReboostOperation', () => {
  it('polls until the saved operation completes', async () => {
    const get = jest.fn()
      .mockResolvedValueOnce({ data: { id: '9', state: 'pending' } })
      .mockResolvedValueOnce({ data: { id: '9', state: 'federating' } })
      .mockResolvedValueOnce({ data: { id: '9', state: 'completed', new_status_id: '50' } });
    const updates = [];

    const operation = await followReboostOperation({
      get,
      statusId: '1',
      operationId: '9',
      onUpdate: (next) => updates.push(next.state),
      wait: immediate,
    });

    expect(operation.state).toBe('completed');
    expect(updates).toEqual(['pending', 'federating', 'completed']);
    expect(get).toHaveBeenCalledWith('/api/v1/statuses/1/reboost_operation', { params: { operation_id: '9' } });
    expect(get.mock.calls.length).toBe(3);
  });

  it('stops after the attempt limit while the operation is still open', async () => {
    const get = jest.fn().mockResolvedValue({ data: { id: '9', state: 'pending' } });

    const operation = await followReboostOperation({
      get,
      statusId: '1',
      operationId: '9',
      wait: (ms) => {
        expect(ms).toBe(REBOOST_POLL_INTERVAL_MS);
        return Promise.resolve();
      },
    });

    expect(operation).toBeNull();
    expect(get).toHaveBeenCalledTimes(REBOOST_POLL_LIMIT);
  });

  it('ignores a different operation id', async () => {
    const get = jest.fn()
      .mockResolvedValueOnce({ data: { id: '10', state: 'completed', new_status_id: '50' } })
      .mockResolvedValueOnce({ data: { id: '9', state: 'cancelled' } });

    const operation = await followReboostOperation({
      get,
      statusId: '1',
      operationId: '9',
      wait: immediate,
    });

    expect(operation).toEqual({ id: '9', state: 'cancelled' });
    expect(get).toHaveBeenCalledWith('/api/v1/statuses/1/reboost_operation', { params: { operation_id: '9' } });
  });

  it('returns a failed operation so the caller can refresh the status', async () => {
    const get = jest.fn().mockResolvedValue({ data: { id: '9', state: 'failed', error: 'create_failed' } });

    const operation = await followReboostOperation({
      get,
      statusId: '1',
      operationId: '9',
      wait: immediate,
    });

    expect(operation).toEqual({ id: '9', state: 'failed', error: 'create_failed' });
  });
});
