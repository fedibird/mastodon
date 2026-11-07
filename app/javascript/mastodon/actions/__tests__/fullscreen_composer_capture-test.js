import { fromJS } from 'immutable';
import api from 'mastodon/api';
import { deleteStatus, editStatus } from '../statuses';
import { setActiveFullscreenComposerId } from '../../utils/fullscreen_column';

jest.mock('mastodon/api', () => {
  const pending = { current: Promise.resolve({ data: {} }) };
  const client = () => ({
    get: () => pending.current,
    delete: () => pending.current,
  });

  client.pending = pending;
  return client;
});

const status = fromJS({
  id: '1',
  visibility: 'public',
  status_reference_ids: [],
});

const stateFor = (composerId) => fromJS({
  statuses: { '1': status },
  fullscreenColumn: composerId ? { open: true, composerId } : null,
  compose: { text: 'primary draft', dirty: true, mounted: true },
  composers: {
    byId: {
      'fullscreen:a': { text: 'draft a', dirty: true, mounted: true },
      'fullscreen:b': { text: 'draft b', dirty: true, mounted: true },
    },
  },
});

const recordingDispatch = (getState) => {
  const actions = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, getState);
    }

    actions.push(action);
    return action;
  };

  return { actions, dispatch };
};

const settle = (executor) => new Promise(executor);

describe('fullscreen composer capture', () => {
  afterEach(() => {
    setActiveFullscreenComposerId(null);
  });

  it('writes a late edit back to the composer that started it', async () => {
    const holder = { composerId: 'fullscreen:a' };
    const { actions, dispatch } = recordingDispatch(() => stateFor(holder.composerId));
    let resolveRequest;

    api.pending.current = settle((resolve) => {
      resolveRequest = resolve;
    });
    setActiveFullscreenComposerId('fullscreen:a');
    dispatch(editStatus('1', { push () {} }));
    holder.composerId = null;
    setActiveFullscreenComposerId(null);
    resolveRequest({ data: { text: 'edited', spoiler_text: '' } });
    await api.pending.current;

    const edits = actions.filter(action => action.type === 'COMPOSE_SET_STATUS');

    expect(edits).toHaveLength(1);
    expect(edits[0].meta.composerId).toBe('fullscreen:a');
    expect(actions.some(action => action.type === 'FULLSCREEN_COLUMN_PATCH')).toBe(false);
  });

  it('does not reveal column B when an edit started in column A', async () => {
    const holder = { composerId: 'fullscreen:a' };
    const { actions, dispatch } = recordingDispatch(() => stateFor(holder.composerId));
    let resolveRequest;

    api.pending.current = settle((resolve) => {
      resolveRequest = resolve;
    });
    setActiveFullscreenComposerId('fullscreen:a');
    dispatch(editStatus('1', { push () {} }));
    holder.composerId = 'fullscreen:b';
    setActiveFullscreenComposerId('fullscreen:b');
    resolveRequest({ data: { text: 'edited', spoiler_text: '' } });
    await api.pending.current;

    const edits = actions.filter(action => action.type === 'COMPOSE_SET_STATUS');

    expect(edits.map(action => action.meta && action.meta.composerId)).toEqual(['fullscreen:a']);
    expect(actions.some(action => action.type === 'FULLSCREEN_COLUMN_PATCH')).toBe(false);
  });

  it('redrafts into the captured composer after the column has closed', async () => {
    const holder = { composerId: 'fullscreen:a' };
    const { actions, dispatch } = recordingDispatch(() => stateFor(holder.composerId));
    let resolveRequest;

    api.pending.current = settle((resolve) => {
      resolveRequest = resolve;
    });
    setActiveFullscreenComposerId('fullscreen:a');
    dispatch(deleteStatus('1', { push () {} }, true));
    holder.composerId = null;
    setActiveFullscreenComposerId(null);
    resolveRequest({ data: { text: 'redraft me' } });
    await api.pending.current;

    const redrafts = actions.filter(action => action.type === 'REDRAFT');

    expect(redrafts).toHaveLength(1);
    expect(redrafts[0].meta.composerId).toBe('fullscreen:a');
    expect(actions.some(action => action.type === 'COMPOSE_REPLY' || action.type === 'COMPOSE_SET_STATUS')).toBe(false);
    expect(actions.some(action => action.type === 'FULLSCREEN_COLUMN_PATCH')).toBe(false);
  });
});
