import { fromJS } from 'immutable';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedStatus: jest.fn(status => ({ type: 'STATUS_IMPORT', status })),
  importFetchedStatuses: jest.fn(() => ({ type: 'STATUSES_IMPORT' })),
  importFetchedAccount: jest.fn(),
}));

jest.mock('../accounts', () => ({
  fetchRelationshipsFromStatus: jest.fn(() => ({ type: 'RELATIONSHIPS_FETCH' })),
  fetchRelationshipsFromStatuses: jest.fn(() => ({ type: 'RELATIONSHIPS_FETCH' })),
}));

jest.mock('../timelines', () => ({
  deleteFromTimelines: jest.fn(() => ({ type: 'TIMELINE_DELETE' })),
  expireFromTimelines: jest.fn(),
}));

jest.mock('../compose', () => ({
  ensureComposeIsVisible: jest.fn(),
  getContextReference: jest.fn(),
}));

import api from '../../api';
import { fetchStatus } from '../statuses';

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

describe('fetchStatus force refresh', () => {
  const loadedState = fromJS({
    statuses: {
      s1: { id: 's1', needs_fetch: false },
    },
  });

  beforeEach(() => {
    api.mockReset();
  });

  it('skips GET when the status is already loaded', async () => {
    const get = jest.fn((url) => {
      if (url.includes('/context')) {
        return Promise.resolve({ data: { ancestors: [], descendants: [], references: [] } });
      }

      return Promise.resolve({ data: { id: 's1' } });
    });
    api.mockReturnValue({ get });

    await dispatchThunk(fetchStatus('s1'), loadedState);

    expect(get.mock.calls.map(call => call[0])).toEqual(['/api/v1/statuses/s1/context']);
  });

  it('force-refreshes even when the status is already loaded', async () => {
    const get = jest.fn((url) => {
      if (url.includes('/context')) {
        return Promise.resolve({ data: { ancestors: [], descendants: [], references: [] } });
      }

      return Promise.resolve({ data: { id: 's1', filtered: [] } });
    });
    api.mockReturnValue({ get });

    await dispatchThunk(fetchStatus('s1', true), loadedState);

    expect(get.mock.calls.map(call => call[0])).toEqual([
      '/api/v1/statuses/s1/context',
      '/api/v1/statuses/s1',
    ]);
  });
});
