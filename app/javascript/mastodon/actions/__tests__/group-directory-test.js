import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
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
import { groupDirectoryFilterKey } from '../../features/group_directory/params';
import userLists from '../../reducers/user_lists';
import { expandGroupDirectory, fetchGroupDirectory } from '../group_directory';
import { importFetchedAccounts } from '../importer';

const page = (start, count) => Array.from({ length: count }, (_, index) => ({
  id: String(start + index),
  group_directory: { software: 'fedibird', languages: [], capabilities: { posting: null } },
}));

const makeStore = (preloadedState = ImmutableMap()) => createStore((state = preloadedState, action) => {
  if (!String(action.type).startsWith('GROUP_DIRECTORY_')) {
    return state;
  }

  return state.set('user_lists', userLists(state.get('user_lists'), action));
}, preloadedState, applyMiddleware(thunk));

const directoryAtOffset = (viewKey, nextOffset) => ImmutableMap({
  user_lists: ImmutableMap({
    group_directories: ImmutableMap({
      [viewKey]: ImmutableMap({
        items: ImmutableList(['1', '2']),
        directories: ImmutableMap(),
        isLoading: false,
        isExpanding: false,
        exhausted: false,
        capped: false,
        error: false,
        failure: null,
        nextOffset,
        filterKey: groupDirectoryFilterKey({ order: 'active' }),
        requestId: 1,
      }),
    }),
  }),
});

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

  it('keeps directory software when the imported account has none', async () => {
    const payload = {
      id: '9',
      username: 'group',
      acct: 'group@lemmy.example',
      display_name: 'Group',
      note: '<p>hello</p>',
      url: 'https://lemmy.example/group',
      emojis: [],
      group_directory: { software: 'lemmy', languages: ['ja'], capabilities: { posting: null } },
    };
    const get = jest.fn().mockResolvedValue({ data: [payload] });
    api.mockReturnValue({ get });
    importFetchedAccounts.mockClear();
    const store = makeStore();

    await store.dispatch(fetchGroupDirectory('column:a', { order: 'active' }));

    const imported = importFetchedAccounts.mock.calls[0][0];
    expect(imported).toHaveLength(1);
    expect(imported[0].id).toBe('9');
    expect(imported[0].group_directory).toBeUndefined();
    expect(directory(store, 'column:a').getIn(['directories', '9', 'software'])).toBe('lemmy');
    expect(directory(store, 'column:a').getIn(['directories', '9', 'languages']).toArray()).toEqual(['ja']);
  });

  it('requests offset 10000 and does not request the following page of 20', async () => {
    const get = jest.fn().mockResolvedValue({ data: page(10001, 20) });
    api.mockReturnValue({ get });
    const store = makeStore(directoryAtOffset('column:a', 10000));

    await store.dispatch(expandGroupDirectory('column:a', { order: 'active' }));

    expect(get).toHaveBeenCalledTimes(1);
    expect(get).toHaveBeenCalledWith('/api/v1/group_directory', {
      params: { order: 'active', limit: 20, offset: 10000 },
    });
    expect(directory(store, 'column:a').get('nextOffset')).toBe(10020);
    expect(directory(store, 'column:a').get('capped')).toBe(false);
    expect(directory(store, 'column:a').get('items').size).toBe(22);

    await store.dispatch(expandGroupDirectory('column:a', { order: 'active' }));

    expect(get).toHaveBeenCalledTimes(1);
    expect(directory(store, 'column:a').get('nextOffset')).toBe(10020);
    expect(directory(store, 'column:a').get('capped')).toBe(true);
    expect(directory(store, 'column:a').get('exhausted')).toBe(true);
    expect(directory(store, 'column:a').get('items').size).toBe(22);
    expect(directory(store, 'column:a').get('error')).toBe(false);
  });

  it('treats an offset rejection as the page limit', async () => {
    const error = new Error('400');
    error.response = { status: 400, data: { error: 'Invalid offset' } };
    const get = jest.fn()
      .mockResolvedValueOnce({ data: page(1, 20) })
      .mockRejectedValueOnce(error);
    api.mockReturnValue({ get });
    const store = makeStore();

    await store.dispatch(fetchGroupDirectory('route', { order: 'active' }));
    await store.dispatch(expandGroupDirectory('route', { order: 'active' }));

    expect(directory(store, 'route').get('capped')).toBe(true);
    expect(directory(store, 'route').get('exhausted')).toBe(true);
    expect(directory(store, 'route').get('error')).toBe(false);
    expect(directory(store, 'route').get('items').size).toBe(20);
    expect(directory(store, 'route').get('nextOffset')).toBe(20);
  });
});
