import { Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: (messages) => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedAccounts: jest.fn(accounts => ({ type: 'ACCOUNTS_IMPORT', accounts })),
}));

jest.mock('../accounts', () => ({
  fetchRelationships: jest.fn(ids => ({ type: 'RELATIONSHIPS_FETCH', ids })),
}));

import api from '../../api';
import userLists from '../../reducers/user_lists';
import { expandGroupDirectory, fetchGroupDirectory } from '../group_directory';

const page = (start, count) => Array.from({ length: count }, (_, index) => ({
  id: String(start + index),
  group_directory: { software: 'fedibird', languages: [], capabilities: { posting: null } },
}));

const makeStore = () => createStore((state = ImmutableMap(), action) => {
  if (!String(action.type).startsWith('GROUP_DIRECTORY_')) {
    return state;
  }

  return state.set('user_lists', userLists(state.get('user_lists'), action));
}, applyMiddleware(thunk));

const directory = (store, viewKey) => store.getState().getIn(['user_lists', 'group_directories', viewKey]);

describe('group directory actions', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('requests the consumed offset after a page that was entirely duplicates', async () => {
    const get = jest.fn()
      .mockResolvedValueOnce({ data: page(1, 20) })
      .mockResolvedValueOnce({ data: page(1, 20) })
      .mockResolvedValueOnce({ data: page(21, 20) });
    api.mockReturnValue({ get });
    const store = makeStore();

    await store.dispatch(fetchGroupDirectory('column:a', { order: 'active' }));
    await store.dispatch(expandGroupDirectory('column:a', { order: 'active' }));

    expect(directory(store, 'column:a').get('items').size).toBe(20);
    expect(directory(store, 'column:a').get('nextOffset')).toBe(40);
    expect(get).toHaveBeenNthCalledWith(2, '/api/v1/group_directory', {
      params: { order: 'active', limit: 20, offset: 20 },
    });

    await store.dispatch(expandGroupDirectory('column:a', { order: 'active' }));

    expect(get).toHaveBeenNthCalledWith(3, '/api/v1/group_directory', {
      params: { order: 'active', limit: 20, offset: 40 },
    });
    expect(directory(store, 'column:a').get('items').size).toBe(40);
    expect(directory(store, 'column:a').get('nextOffset')).toBe(60);
  });

  it('retries a failed extra page at the same offset and keeps the loaded rows', async () => {
    const get = jest.fn()
      .mockResolvedValueOnce({ data: page(1, 20) })
      .mockRejectedValueOnce(new Error('500'))
      .mockResolvedValueOnce({ data: page(21, 5) });
    api.mockReturnValue({ get });
    const store = makeStore();

    await store.dispatch(fetchGroupDirectory('route', { order: 'active' }));
    await store.dispatch(expandGroupDirectory('route', { order: 'active' }));

    expect(directory(store, 'route').get('items').size).toBe(20);
    expect(directory(store, 'route').get('directories').size).toBe(20);
    expect(directory(store, 'route').get('nextOffset')).toBe(20);
    expect(directory(store, 'route').get('failure')).toBe('expand');

    await store.dispatch(expandGroupDirectory('route', { order: 'active' }));

    expect(get).toHaveBeenNthCalledWith(2, '/api/v1/group_directory', {
      params: { order: 'active', limit: 20, offset: 20 },
    });
    expect(get).toHaveBeenNthCalledWith(3, '/api/v1/group_directory', {
      params: { order: 'active', limit: 20, offset: 20 },
    });
    expect(directory(store, 'route').get('items').toArray()).toEqual(page(1, 25).map(account => account.id));
    expect(directory(store, 'route').get('nextOffset')).toBe(25);
    expect(directory(store, 'route').get('failure')).toBe(null);
    expect(directory(store, 'route').get('error')).toBe(false);
  });

  it('retries a failed first page from the beginning and does not expand it', async () => {
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('500'))
      .mockResolvedValueOnce({ data: page(1, 2) });
    api.mockReturnValue({ get });
    const store = makeStore();

    await store.dispatch(fetchGroupDirectory('route', { order: 'active' }));

    expect(directory(store, 'route').get('failure')).toBe('fetch');
    expect(directory(store, 'route').get('items').size).toBe(0);
    expect(directory(store, 'route').get('nextOffset')).toBe(0);

    await store.dispatch(expandGroupDirectory('route', { order: 'active' }));
    expect(get).toHaveBeenCalledTimes(1);

    await store.dispatch(fetchGroupDirectory('route', { order: 'active' }));

    expect(get).toHaveBeenNthCalledWith(2, '/api/v1/group_directory', {
      params: { order: 'active', limit: 20 },
    });
    expect(directory(store, 'route').get('items').toArray()).toEqual(['1', '2']);
    expect(directory(store, 'route').get('nextOffset')).toBe(2);
    expect(directory(store, 'route').get('failure')).toBe(null);
  });
});
