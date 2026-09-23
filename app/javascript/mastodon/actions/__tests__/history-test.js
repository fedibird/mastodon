import { Map as ImmutableMap } from 'immutable';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedAccounts: jest.fn(accounts => ({ type: 'ACCOUNTS_IMPORT', accounts })),
}));

import api from '../../api';
import { importFetchedAccounts } from '../importer';
import { fetchHistory } from '../history';

const dispatchThunk = (thunk, state) => {
  const actions = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    actions.push(action);
    return action;
  };

  return Promise.resolve(thunk(dispatch, () => state)).then(() => actions);
};

describe('fetchHistory', () => {
  const state = ImmutableMap();

  beforeEach(() => {
    api.mockReset();
    importFetchedAccounts.mockClear();
  });

  it('stores history revisions on success', async () => {
    const history = [{
      content: '<p>old</p>',
      spoiler_text: 'cw',
      sensitive: false,
      created_at: '2026-01-01T00:00:00.000Z',
      account: { id: 'a1' },
      media_attachments: [],
    }];
    api.mockReturnValue({
      get: jest.fn().mockResolvedValue({ data: history }),
    });

    const actions = await dispatchThunk(fetchHistory('s1'), state);

    expect(api().get).toHaveBeenCalledWith('/api/v1/statuses/s1/history');
    expect(actions.map(action => action.type)).toEqual([
      'HISTORY_FETCH_REQUEST',
      'ACCOUNTS_IMPORT',
      'HISTORY_FETCH_SUCCESS',
    ]);
    expect(actions[2].history).toEqual(history);
  });

  it('records a failure without pretending history loaded', async () => {
    const error = new Error('nope');
    api.mockReturnValue({
      get: jest.fn().mockRejectedValue(error),
    });

    const actions = await dispatchThunk(fetchHistory('s1'), state);

    expect(actions.map(action => action.type)).toEqual([
      'HISTORY_FETCH_REQUEST',
      'HISTORY_FETCH_FAIL',
    ]);
    expect(actions[1].error).toBe(error);
    expect(actions[1].statusId).toEqual('s1');
  });
});
