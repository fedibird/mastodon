jest.mock('react-intl', () => ({
  defineMessages: (messages) => messages,
}));

import { Map as ImmutableMap } from 'immutable';
import userLists from '../user_lists';
import {
  GROUP_DIRECTORY_DISCARD,
  GROUP_DIRECTORY_EXPAND_REQUEST,
  GROUP_DIRECTORY_EXPAND_SUCCESS,
  GROUP_DIRECTORY_FETCH_FAIL,
  GROUP_DIRECTORY_FETCH_REQUEST,
  GROUP_DIRECTORY_FETCH_SUCCESS,
} from '../../actions/group_directory';
import { COLUMN_REMOVE } from '../../actions/columns';

const account = (id, software) => ({
  id,
  group_directory: { software, languages: [], capabilities: { posting: null } },
});

const fetch = (viewKey, filterKey, requestId) => ({
  type: GROUP_DIRECTORY_FETCH_REQUEST,
  viewKey,
  filterKey,
  requestId,
});

describe('group directory lists', () => {
  it('keeps two columns and drops a stale response', () => {
    let state = userLists(undefined, fetch('column:a', 'active\nall\n\n', 1));
    state = userLists(state, fetch('column:b', 'new\nlocal\nlemmy\nbooks', 1));
    state = userLists(state, {
      type: GROUP_DIRECTORY_FETCH_SUCCESS,
      viewKey: 'column:a',
      filterKey: 'active\nall\n\n',
      requestId: 1,
      accounts: [account('1', 'fedibird')],
      exhausted: false,
    });
    state = userLists(state, {
      type: GROUP_DIRECTORY_FETCH_SUCCESS,
      viewKey: 'column:a',
      filterKey: 'active\nall\n\n',
      requestId: 0,
      accounts: [account('stale', 'peertube')],
      exhausted: true,
    });

    expect(state.getIn(['group_directories', 'column:a', 'items']).toArray()).toEqual(['1']);
    expect(state.getIn(['group_directories', 'column:a', 'directories', '1', 'software'])).toEqual('fedibird');
    expect(state.getIn(['group_directories', 'column:b', 'items']).toArray()).toEqual([]);
    expect(state.getIn(['group_directories', 'column:b', 'filterKey'])).toEqual('new\nlocal\nlemmy\nbooks');
    expect(state.getIn(['group_directories', 'column:b', 'isLoading'])).toBe(true);
  });

  it('replaces items when the filter changes and refuses to append another filter', () => {
    let state = userLists(undefined, fetch('route', 'first', 1));
    state = userLists(state, {
      type: GROUP_DIRECTORY_FETCH_SUCCESS,
      viewKey: 'route',
      filterKey: 'first',
      requestId: 1,
      accounts: [account('1', 'lemmy'), account('2', null)],
      exhausted: false,
    });
    state = userLists(state, fetch('route', 'second', 2));
    state = userLists(state, {
      type: GROUP_DIRECTORY_EXPAND_SUCCESS,
      viewKey: 'route',
      filterKey: 'first',
      requestId: 1,
      accounts: [account('3', 'lemmy')],
      exhausted: true,
    });

    expect(state.getIn(['group_directories', 'route', 'items']).toArray()).toEqual([]);
    expect(state.getIn(['group_directories', 'route', 'filterKey'])).toEqual('second');
    expect(state.getIn(['group_directories', 'route', 'isLoading'])).toBe(true);
  });

  it('appends the next page once and records the end', () => {
    let state = userLists(undefined, fetch('column:a', 'same', 4));
    state = userLists(state, {
      type: GROUP_DIRECTORY_FETCH_SUCCESS,
      viewKey: 'column:a',
      filterKey: 'same',
      requestId: 4,
      accounts: [account('1', 'fedibird')],
      exhausted: false,
    });
    state = userLists(state, {
      type: GROUP_DIRECTORY_EXPAND_REQUEST,
      viewKey: 'column:a',
      filterKey: 'same',
      requestId: 5,
    });
    state = userLists(state, {
      type: GROUP_DIRECTORY_EXPAND_SUCCESS,
      viewKey: 'column:a',
      filterKey: 'same',
      requestId: 5,
      accounts: [account('1', 'fedibird'), account('2', null)],
      exhausted: true,
    });

    expect(state.getIn(['group_directories', 'column:a', 'items']).toArray()).toEqual(['1', '2']);
    expect(state.getIn(['group_directories', 'column:a', 'exhausted'])).toBe(true);
    expect(state.getIn(['group_directories', 'column:a', 'isExpanding'])).toBe(false);
    expect(state.getIn(['group_directories', 'column:a', 'directories']).keySeq().toArray()).toEqual(['1', '2']);
  });

  it('keeps an error distinct from an empty result and ignores a late success', () => {
    let state = userLists(undefined, fetch('route', 'same', 1));
    state = userLists(state, {
      type: GROUP_DIRECTORY_FETCH_FAIL,
      viewKey: 'route',
      filterKey: 'same',
      requestId: 1,
      error: new Error('offline'),
    });
    state = userLists(state, {
      type: GROUP_DIRECTORY_FETCH_SUCCESS,
      viewKey: 'route',
      filterKey: 'same',
      requestId: 0,
      accounts: [],
      exhausted: true,
    });

    expect(state.getIn(['group_directories', 'route', 'error'])).toBe(true);
    expect(state.getIn(['group_directories', 'route', 'items']).size).toBe(0);
    expect(state.getIn(['group_directories', 'route', 'isLoading'])).toBe(false);
  });

  it('releases a closed column without touching another view', () => {
    let state = userLists(undefined, fetch('column:a', 'same', 1));
    state = userLists(state, fetch('column:b', 'same', 1));
    state = userLists(state, fetch('route', 'same', 1));
    state = userLists(state, { type: GROUP_DIRECTORY_DISCARD, viewKey: 'route' });
    state = userLists(state, { type: COLUMN_REMOVE, uuid: 'a' });

    expect(state.getIn(['group_directories', 'route'])).toBeUndefined();
    expect(state.getIn(['group_directories', 'column:a'])).toBeUndefined();
    expect(state.getIn(['group_directories', 'column:b', 'filterKey'])).toEqual('same');
    expect(state.get('followers')).toEqual(ImmutableMap());
  });
});
