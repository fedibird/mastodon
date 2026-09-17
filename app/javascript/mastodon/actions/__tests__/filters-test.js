import { fromJS } from 'immutable';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFilters: jest.fn(filters => ({ type: 'FILTERS_IMPORT', filters })),
}));

jest.mock('../statuses', () => ({
  fetchStatus: jest.fn((id, force) => ({ type: 'STATUS_FETCH', id, force })),
}));

jest.mock('../modal', () => ({
  openModal: (type, props) => ({ type: 'MODAL_OPEN', modalType: type, modalProps: props }),
}));

import api from '../../api';
import { importFilters } from '../importer';
import { fetchStatus } from '../statuses';
import {
  initAddFilter,
  fetchFilters,
  createFilter,
  createFilterStatus,
} from '../filters';

const dispatchThunk = (thunk, state = fromJS({})) => {
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

describe('filter actions', () => {
  beforeEach(() => {
    api.mockReset();
    importFilters.mockClear();
    fetchStatus.mockClear();
  });

  it('opens the FILTER modal with the status id and context', async () => {
    const status = fromJS({ id: 's1' });
    const actions = await dispatchThunk(initAddFilter(status, { contextType: 'home' }));

    expect(actions).toEqual([{
      type: 'MODAL_OPEN',
      modalType: 'FILTER',
      modalProps: { statusId: 's1', contextType: 'home' },
    }]);
  });

  it('fetches Filters v2 and replaces the collection without a redundant import', async () => {
    const filters = [{ id: '1', title: 'spoilers', keywords: [{ keyword: 'foo' }] }];
    api.mockReturnValue({
      get: jest.fn().mockResolvedValue({ data: filters }),
    });

    const actions = await dispatchThunk(fetchFilters());

    expect(api().get).toHaveBeenCalledWith('/api/v2/filters');
    expect(importFilters).not.toHaveBeenCalled();
    expect(actions.map(action => action.type)).toEqual([
      'FILTERS_FETCH_REQUEST',
      'FILTERS_FETCH_SUCCESS',
    ]);
    expect(actions[1]).toEqual({
      type: 'FILTERS_FETCH_SUCCESS',
      filters,
      skipLoading: true,
    });
  });

  it('creates a filter with filter_action rather than action', async () => {
    const created = { id: '9', title: 'new', filter_action: 'warn' };
    api.mockReturnValue({
      post: jest.fn().mockResolvedValue({ data: created }),
    });
    const onSuccess = jest.fn();

    await dispatchThunk(createFilter({
      title: 'new',
      context: ['home', 'notifications', 'public', 'thread', 'account'],
      filter_action: 'warn',
    }, onSuccess));

    expect(api().post).toHaveBeenCalledWith('/api/v2/filters', {
      title: 'new',
      context: ['home', 'notifications', 'public', 'thread', 'account'],
      filter_action: 'warn',
    });
    expect(onSuccess).toHaveBeenCalledWith(created);
    expect(importFilters).toHaveBeenCalledWith([created]);
  });

  it('attaches a status then force-refreshes it', async () => {
    api.mockReturnValue({
      post: jest.fn().mockResolvedValue({ data: { id: 'fs1', status_id: 's1' } }),
    });
    const onSuccess = jest.fn();

    const actions = await dispatchThunk(createFilterStatus({
      filter_id: '1',
      status_id: 's1',
    }, onSuccess));

    expect(api().post).toHaveBeenCalledWith('/api/v2/filters/1/statuses', { status_id: 's1' });
    expect(fetchStatus).toHaveBeenCalledWith('s1', true);
    expect(onSuccess).toHaveBeenCalled();
    expect(actions.map(action => action.type)).toEqual([
      'FILTERS_STATUS_CREATE_REQUEST',
      'FILTERS_STATUS_CREATE_SUCCESS',
      'STATUS_FETCH',
    ]);
  });

  it('invokes onFail when attaching a status is rejected', async () => {
    const error = new Error('nope');
    api.mockReturnValue({
      post: jest.fn().mockRejectedValue(error),
    });
    const onFail = jest.fn();

    const actions = await dispatchThunk(createFilterStatus({
      filter_id: '1',
      status_id: 's1',
    }, jest.fn(), onFail));

    expect(onFail).toHaveBeenCalledWith(error);
    expect(fetchStatus).not.toHaveBeenCalled();
    expect(actions.map(action => action.type)).toEqual([
      'FILTERS_STATUS_CREATE_REQUEST',
      'FILTERS_STATUS_CREATE_FAIL',
    ]);
  });
});
