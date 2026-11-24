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
import { reboost, REBOOST_OPERATION, REBLOG_SUCCESS } from '../interactions';
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
    if (action.type === REBOOST_OPERATION || action.type === STATUS_IMPORT) {
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

  it('keeps the in-flight operation when a status payload is imported', () => {
    let state = ImmutableMap({ '1': ImmutableMap({ id: '1', reblogged: true }) });
    state = statuses(state, { type: REBOOST_OPERATION, statusId: '1', operation: { id: '9', state: 'pending' } });
    state = statuses(state, { type: STATUS_IMPORT, status: { id: '1', reblogged: true, content: 'updated' } });

    expect(state.getIn(['1', 'content'])).toBe('updated');
    expect(state.getIn(['1', 'reboost_operation']).toJS()).toEqual({ id: '9', state: 'pending' });
  });
});
