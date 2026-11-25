import { Map as ImmutableMap } from 'immutable';

jest.mock('../../api', () => {
  const post = jest.fn();
  const get = jest.fn();
  const api = () => ({ post, get });
  api.post = post;
  api.get = get;
  return {
    __esModule: true,
    default: api,
    getLinks: () => ({ refs: [] }),
  };
});

jest.mock('../../features/reboost/follow_operation', () => ({
  followReboostOperation: jest.fn(),
}));

jest.mock('../importer', () => ({
  STATUS_IMPORT: 'STATUS_IMPORT',
  importFetchedStatus: jest.fn(status => ({ type: 'STATUS_IMPORT', status })),
  importFetchedStatuses: jest.fn(),
  importFetchedAccounts: jest.fn(),
}));

import api from '../../api';
import { followReboostOperation } from '../../features/reboost/follow_operation';
import { importFetchedStatus, STATUS_IMPORT } from '../importer';
import { checkReboostOperation, reblog, reboost, unreblog, REBOOST_OPERATION, REBLOG_SUCCESS, UNREBLOG_FAIL, UNREBLOG_REQUEST } from '../interactions';
import { reboostRemainingSeconds } from '../../features/reboost/menu';
import statuses from '../../reducers/statuses';

const status = ImmutableMap({ id: '1', reblogged: true });

const setup = () => {
  const actions = [];
  let state = ImmutableMap({
    statuses: statuses(undefined, { type: '@@INIT' }).set('1', ImmutableMap({ id: '1', reblogged: true })),
  });
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }
    actions.push(action);
    if ([REBOOST_OPERATION, STATUS_IMPORT, REBLOG_SUCCESS, UNREBLOG_REQUEST, UNREBLOG_FAIL].includes(action.type)) {
      state = state.set('statuses', statuses(state.get('statuses'), action));
    }
    return action;
  };

  return { actions, dispatch, getState: () => state };
};

describe('reboost', () => {
  beforeEach(() => {
    api.post.mockReset();
    api.get.mockReset();
    followReboostOperation.mockReset();
    importFetchedStatus.mockClear();
  });

  it('imports a completed replacement and keeps the original boosted', async () => {
    api.post.mockResolvedValue({ status: 200, data: { id: '50', reblog: { id: '1', reblogged: true } } });
    const { actions, dispatch, getState } = setup();

    await reboost(status)(dispatch, getState);

    expect(api.post).toHaveBeenCalledWith('/api/v1/statuses/1/reblog', { reboost: true }, {
      headers: { 'Idempotency-Key': expect.any(String) },
    });
    expect(importFetchedStatus).toHaveBeenCalledWith({ id: '50', reblog: { id: '1', reblogged: true } });
    expect(actions.some(action => action.type === REBLOG_SUCCESS)).toBe(true);
    expect(getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(followReboostOperation).not.toHaveBeenCalled();
  });

  it('polls a 202 and imports the new status when the operation completes', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockImplementation(({ onUpdate }) => {
      onUpdate({ id: '9', state: 'federating' });
      return Promise.resolve({ id: '9', state: 'completed', new_status_id: '50' });
    });
    api.get.mockResolvedValue({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    const { actions, dispatch, getState } = setup();

    await reboost(status)(dispatch, getState);

    expect(followReboostOperation).toHaveBeenCalledWith(expect.objectContaining({
      statusId: '1',
      operationId: '9',
    }));
    expect(api.get).toHaveBeenCalledWith('/api/v1/statuses/50');
    expect(actions.some(action => action.type === REBLOG_SUCCESS)).toBe(true);
    expect(getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
  });

  it('refreshes the original status when the operation fails', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'failed', error: 'create_failed' });
    api.get.mockResolvedValue({ data: { id: '1', reblogged: false } });
    const { actions, dispatch, getState } = setup();

    await reboost(status)(dispatch, getState);

    expect(api.get).toHaveBeenCalledWith('/api/v1/statuses/1');
    expect(importFetchedStatus).toHaveBeenCalledWith({ id: '1', reblogged: false });
    expect(actions.some(action => action.type === 'ALERT_SHOW' && action.title.id === 'reboost.failed_title')).toBe(true);
    expect(actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
    expect(getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
  });

  it('keeps the same operation when the status check fails and does not post again', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockRejectedValue(new Error('timeout'));
    const harness = setup();

    await reboost(status)(harness.dispatch, harness.getState);

    expect(harness.actions.some(action => action.type === 'ALERT_SHOW' && action.title.id === 'reboost.still_pending_title')).toBe(true);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation']).toJS()).toEqual({ id: '9', state: 'pending' });

    api.post.mockClear();
    await reboost(status)(harness.dispatch, harness.getState);
    expect(api.post).not.toHaveBeenCalled();
  });

  it('tells the viewer when polling ends before the operation does', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockResolvedValue(null);
    const { actions, dispatch, getState } = setup();

    await reboost(status)(dispatch, getState);

    expect(actions.some(action => action.type === 'ALERT_SHOW' && action.title.id === 'reboost.still_pending_title')).toBe(true);
    expect(getState().getIn(['statuses', '1', 'reboost_operation']).toJS()).toEqual({ id: '9', state: 'pending' });
  });

  it('does not mark the post boosted when the operation completes without a new status', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'completed', new_status_id: null });
    api.get.mockResolvedValue({ data: { id: '1', reblogged: false } });
    const { actions, dispatch, getState } = setup();

    await reboost(status)(dispatch, getState);

    expect(actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
    expect(actions.some(action => action.type === 'ALERT_SHOW' && action.title.id === 'reboost.failed_title')).toBe(true);
    expect(getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
  });

  it('does not mark the post boosted when the operation is cancelled', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'cancelled', new_status_id: null });
    api.get.mockResolvedValue({ data: { id: '1', reblogged: false } });
    const { actions, dispatch, getState } = setup();

    await reboost(status)(dispatch, getState);

    expect(actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
    expect(actions.some(action => action.type === 'ALERT_SHOW' && action.title.id === 'reboost.cancelled_title')).toBe(true);
  });

  it('reuses the idempotency key when the reboost request never receives a response', async () => {
    api.post.mockRejectedValueOnce(new Error('network'));
    const { dispatch, getState } = setup();

    await reboost(status)(dispatch, getState);
    const firstKey = api.post.mock.calls[0][2].headers['Idempotency-Key'];

    api.post.mockResolvedValue({ status: 200, data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await reboost(status)(dispatch, getState);

    expect(api.post.mock.calls[1][2].headers['Idempotency-Key']).toBe(firstKey);
  });

  it('shows the remaining seconds on 429 and does not start another request while one is open', async () => {
    api.post.mockRejectedValue({ response: { status: 429, data: { retry_after: 42 } } });
    const harness = setup();

    await reboost(status)(harness.dispatch, harness.getState);

    expect(harness.actions.some(action => action.type === 'ALERT_SHOW' && action.message_values.seconds === 42)).toBe(true);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();

    const busy = harness.getState().set('statuses', statuses(harness.getState().get('statuses'), {
      type: REBOOST_OPERATION,
      statusId: '1',
      operation: { id: '9', state: 'pending' },
    }));
    api.post.mockClear();
    await reboost(status)(harness.dispatch, () => busy);
    expect(api.post).not.toHaveBeenCalled();
  });

  it('follows a normal boost that is answered with 202 until it completes', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'completed', new_status_id: '50' });
    api.get.mockResolvedValue({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    const { actions, dispatch, getState } = setup();

    await reblog(status)(dispatch, getState);

    expect(api.post).toHaveBeenCalledWith('/api/v1/statuses/1/reblog', { visibility: undefined });
    expect(importFetchedStatus).toHaveBeenCalledWith({ id: '50', reblog: { id: '1', reblogged: true } });
    expect(actions.some(action => action.type === REBLOG_SUCCESS)).toBe(true);
    expect(getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
  });

  it('follows a normal boost that is answered with 202 until it is cancelled or fails', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'cancelled', new_status_id: null });
    api.get.mockResolvedValue({ data: { id: '1', reblogged: false } });
    const cancelled = setup();

    await reblog(status)(cancelled.dispatch, cancelled.getState);

    expect(cancelled.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
    expect(cancelled.actions.some(action => action.type === 'ALERT_SHOW' && action.title.id === 'reboost.cancelled_title')).toBe(true);
    expect(cancelled.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();

    followReboostOperation.mockResolvedValue({ id: '9', state: 'failed', new_status_id: null });
    const failed = setup();

    await reblog(status)(failed.dispatch, failed.getState);

    expect(failed.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
    expect(failed.actions.some(action => action.type === 'ALERT_SHOW' && action.title.id === 'reboost.failed_title')).toBe(true);
  });

  it('reports a disabled reboost from a normal boost as a failure', async () => {
    api.post.mockRejectedValue({ response: { status: 403, data: { error: 'reboost disabled' } } });
    const { actions, dispatch, getState } = setup();

    await reblog(status)(dispatch, getState);

    expect(actions.some(action => action.type === 'REBLOG_FAIL')).toBe(true);
    expect(actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
  });

  it('checks the saved operation without posting again', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockRejectedValue(new Error('timeout'));
    const harness = setup();

    await reboost(status)(harness.dispatch, harness.getState);
    api.post.mockClear();
    api.get.mockResolvedValueOnce({ data: { id: '9', state: 'completed', new_status_id: '50' } });
    api.get.mockResolvedValueOnce({ data: { id: '50', reblog: { id: '1', reblogged: true } } });

    await checkReboostOperation(status)(harness.dispatch, harness.getState);

    expect(api.post).not.toHaveBeenCalled();
    expect(api.get).toHaveBeenCalledWith('/api/v1/statuses/1/reboost_operation', { params: { operation_id: '9' } });
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(true);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
  });

  it('keeps a pending check and applies the same operation when it completes', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockRejectedValue(new Error('timeout'));
    const harness = setup();

    await reboost(status)(harness.dispatch, harness.getState);
    api.post.mockClear();
    api.get.mockResolvedValueOnce({ data: { id: '9', state: 'pending' } });

    await checkReboostOperation(status)(harness.dispatch, harness.getState);

    expect(api.post).not.toHaveBeenCalled();
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation']).toJS()).toEqual({ id: '9', state: 'pending' });
    expect(harness.actions.some(action => action.type === 'ALERT_SHOW' && action.title.id === 'reboost.failed_title')).toBe(false);

    api.get.mockResolvedValueOnce({ data: { id: '8', state: 'failed' } });
    await checkReboostOperation(status)(harness.dispatch, harness.getState);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation']).toJS()).toEqual({ id: '9', state: 'pending' });

    api.get.mockResolvedValueOnce({ data: { id: '9', state: 'federating' } });
    await checkReboostOperation(status)(harness.dispatch, harness.getState);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation']).toJS()).toEqual({ id: '9', state: 'federating' });

    api.get.mockResolvedValueOnce({ data: { id: '9', state: 'completed', new_status_id: '50' } });
    api.get.mockResolvedValueOnce({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await checkReboostOperation(status)(harness.dispatch, harness.getState);

    expect(api.post).not.toHaveBeenCalled();
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(true);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
  });

  it('keeps the in-flight operation when a status payload is imported', () => {
    let state = ImmutableMap({ '1': ImmutableMap({ id: '1', reblogged: true }) });
    state = statuses(state, { type: REBOOST_OPERATION, statusId: '1', operation: { id: '9', state: 'pending' } });
    state = statuses(state, { type: STATUS_IMPORT, status: { id: '1', reblogged: true, content: 'updated' } });

    expect(state.getIn(['1', 'content'])).toBe('updated');
    expect(state.getIn(['1', 'reboost_operation']).toJS()).toEqual({ id: '9', state: 'pending' });
  });

  it('ignores a late poll after a manual check already finished', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    let finishFollow;
    let reportUpdate;
    followReboostOperation.mockImplementation(({ onUpdate }) => {
      reportUpdate = onUpdate;
      return new Promise((resolve, reject) => {
        finishFollow = { resolve, reject };
      });
    });
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();

    api.get.mockResolvedValueOnce({ data: { id: '9', state: 'completed', new_status_id: '50' } });
    api.get.mockResolvedValueOnce({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await checkReboostOperation(status)(harness.dispatch, harness.getState);

    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(true);

    reportUpdate({ id: '9', state: 'pending' });
    finishFollow.resolve({ id: '9', state: 'pending' });
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
  });

  it('ignores a late poll timeout after a manual check already finished', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    let finishFollow;
    followReboostOperation.mockImplementation(() => new Promise((resolve, reject) => {
      finishFollow = { resolve, reject };
    }));
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();

    api.get.mockResolvedValueOnce({ data: { id: '9', state: 'completed', new_status_id: '50' } });
    api.get.mockResolvedValueOnce({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await checkReboostOperation(status)(harness.dispatch, harness.getState);

    finishFollow.reject(new Error('timeout'));
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
  });

  it('does not let a late status fetch clear a newer operation', async () => {
    api.post.mockResolvedValue({ status: 202, data: { operation_id: '9', state: 'pending' } });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'completed', new_status_id: '50' });
    let finishStatus;
    api.get.mockImplementation((url) => {
      if (url === '/api/v1/statuses/50') {
        return new Promise((resolve) => {
          finishStatus = resolve;
        });
      }
      return Promise.resolve({ data: { id: '1' } });
    });
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();
    await Promise.resolve();

    harness.dispatch({ type: REBOOST_OPERATION, statusId: '1', operation: { id: '10', state: 'pending' } });
    finishStatus({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation']).toJS()).toEqual({ id: '10', state: 'pending' });
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
  });

  it('does not let a late replacement fetch restore a boost after unreblog', async () => {
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return Promise.resolve({ data: { id: '1', reblogged: false } });
      }
      return Promise.resolve({ status: 202, data: { operation_id: '9', state: 'pending' } });
    });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'completed', new_status_id: '50' });
    let finishStatus;
    api.get.mockImplementation((url) => {
      if (url === '/api/v1/statuses/50') {
        return new Promise((resolve) => {
          finishStatus = resolve;
        });
      }
      return Promise.resolve({ data: { id: '1' } });
    });
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();
    await Promise.resolve();

    await unreblog(status)(harness.dispatch, harness.getState);
    finishStatus({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reblogged'])).toBe(false);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
  });

  it('keeps the replacement fetch when unreblog fails', async () => {
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return Promise.reject(new Error('unreblog failed'));
      }
      return Promise.resolve({ status: 202, data: { operation_id: '9', state: 'pending' } });
    });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'completed', new_status_id: '50' });
    let finishStatus;
    api.get.mockImplementation((url) => {
      if (url === '/api/v1/statuses/50') {
        return new Promise((resolve) => {
          finishStatus = resolve;
        });
      }
      return Promise.resolve({ data: { id: '1' } });
    });
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();
    await Promise.resolve();

    await unreblog(status)(harness.dispatch, harness.getState);
    finishStatus({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reblogged'])).toBe(true);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(true);
  });

  it('ignores a late boost response after unreblog succeeds', async () => {
    let finishReboost;
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return Promise.resolve({ data: { id: '1', reblogged: false } });
      }
      return new Promise((resolve) => {
        finishReboost = resolve;
      });
    });
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();

    await unreblog(status)(harness.dispatch, harness.getState);
    finishReboost({ status: 200, data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reblogged'])).toBe(false);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
  });

  it('ignores a late accepted reboost after unreblog succeeds', async () => {
    let finishReboost;
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return Promise.resolve({ data: { id: '1', reblogged: false } });
      }
      return new Promise((resolve) => {
        finishReboost = resolve;
      });
    });
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();

    await unreblog(status)(harness.dispatch, harness.getState);
    finishReboost({ status: 202, data: { operation_id: '9', state: 'pending' } });
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(followReboostOperation).not.toHaveBeenCalled();
  });

  it('keeps a replacement that arrived while unreblog was failing', async () => {
    let finishUnreblog;
    let finishStatus;
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return new Promise((resolve, reject) => {
          finishUnreblog = { resolve, reject };
        });
      }
      return Promise.resolve({ status: 202, data: { operation_id: '9', state: 'pending' } });
    });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'completed', new_status_id: '50' });
    api.get.mockImplementation((url) => {
      if (url === '/api/v1/statuses/50') {
        return new Promise((resolve) => {
          finishStatus = resolve;
        });
      }
      return Promise.resolve({ data: { id: '1' } });
    });
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();
    await Promise.resolve();

    const removing = unreblog(status)(harness.dispatch, harness.getState);
    finishStatus({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await Promise.resolve();
    finishUnreblog.reject(new Error('unreblog failed'));
    await removing;
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reblogged'])).toBe(true);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(true);
  });

  it('does not start another request while unreblog is in flight', async () => {
    let finishUnreblog;
    let finishStatus;
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return new Promise((resolve) => {
          finishUnreblog = resolve;
        });
      }
      return Promise.resolve({ status: 202, data: { operation_id: '9', state: 'pending' } });
    });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'completed', new_status_id: '50' });
    api.get.mockImplementation((url) => {
      if (url === '/api/v1/statuses/50') {
        return new Promise((resolve) => {
          finishStatus = resolve;
        });
      }
      return Promise.resolve({ data: { id: '1' } });
    });
    const harness = setup();
    const running = reboost(status)(harness.dispatch, harness.getState);
    await Promise.resolve();
    await Promise.resolve();

    const removing = unreblog(status)(harness.dispatch, harness.getState);
    await Promise.resolve();
    const posts = api.post.mock.calls.length;
    await checkReboostOperation(status)(harness.dispatch, harness.getState);
    await unreblog(status)(harness.dispatch, harness.getState);
    await reblog(status)(harness.dispatch, harness.getState);

    expect(api.post.mock.calls.length).toBe(posts);
    expect(api.get.mock.calls.some((call) => String(call[0]).includes('reboost_operation'))).toBe(false);

    finishStatus({ data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await Promise.resolve();
    finishUnreblog({ data: { id: '1', reblogged: false } });
    await removing;
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reblogged'])).toBe(false);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
  });

  it('ignores a late accepted normal boost after unreblog succeeds', async () => {
    let finishReblog;
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return Promise.resolve({ data: { id: '1', reblogged: false } });
      }
      return new Promise((resolve) => {
        finishReblog = resolve;
      });
    });
    const harness = setup();
    const running = reblog(status)(harness.dispatch, harness.getState);
    await Promise.resolve();

    await unreblog(status)(harness.dispatch, harness.getState);
    finishReblog({ status: 202, data: { operation_id: '9', state: 'pending' } });
    await running;

    expect(harness.getState().getIn(['statuses', '1', 'reblogged'])).toBe(false);
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation'])).toBeUndefined();
    expect(followReboostOperation).not.toHaveBeenCalled();
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
  });

  it('ignores a late normal boost response after unreblog succeeds', async () => {
    let finishReblog;
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return Promise.resolve({ data: { id: '1', reblogged: false } });
      }
      return new Promise((resolve) => {
        finishReblog = resolve;
      });
    });
    const harness = setup();
    const running = reblog(status)(harness.dispatch, harness.getState);
    await Promise.resolve();

    await unreblog(status)(harness.dispatch, harness.getState);
    const imports = importFetchedStatus.mock.calls.length;
    finishReblog({ status: 200, data: { id: '50', reblog: { id: '1', reblogged: true } } });
    await running;

    expect(importFetchedStatus.mock.calls.length).toBe(imports);
    expect(harness.getState().getIn(['statuses', '1', 'reblogged'])).toBe(false);
    expect(harness.actions.some(action => action.type === REBLOG_SUCCESS)).toBe(false);
  });

  it('applies a normal boost that arrived while unreblog was failing', async () => {
    let finishUnreblog;
    let finishReblog;
    api.post.mockImplementation((url) => {
      if (String(url).endsWith('/unreblog')) {
        return new Promise((resolve, reject) => {
          finishUnreblog = { resolve, reject };
        });
      }
      return new Promise((resolve) => {
        finishReblog = resolve;
      });
    });
    followReboostOperation.mockResolvedValue({ id: '9', state: 'pending' });
    const harness = setup();
    const running = reblog(status)(harness.dispatch, harness.getState);
    await Promise.resolve();

    const removing = unreblog(status)(harness.dispatch, harness.getState);
    finishReblog({ status: 202, data: { operation_id: '9', state: 'pending' } });
    await Promise.resolve();
    await Promise.resolve();
    finishUnreblog.reject(new Error('unreblog failed'));
    await removing;
    await running;

    expect(followReboostOperation).toHaveBeenCalled();
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation', 'id'])).toBe('9');
    expect(harness.getState().getIn(['statuses', '1', 'reboost_operation', 'state'])).toBe('pending');
  });

  it('turns a cooldown into a deadline that expires', () => {
    jest.useFakeTimers('modern');
    jest.setSystemTime(new Date('2026-11-24T00:00:00Z'));
    const state = statuses(ImmutableMap(), { type: STATUS_IMPORT, status: { id: '1', reboost_retry_after: 300 } });

    expect(state.getIn(['1', 'reboost_retry_until'])).toBe(Date.now() + 300000);
    expect(reboostRemainingSeconds(state.get('1'))).toBe(300);
    jest.setSystemTime(new Date('2026-11-24T00:05:00Z'));
    expect(reboostRemainingSeconds(state.get('1'))).toBe(0);
    jest.useRealTimers();
  });
});
