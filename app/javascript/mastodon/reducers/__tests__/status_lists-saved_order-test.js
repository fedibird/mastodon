import { fromJS } from 'immutable';
import reducer from '../status_lists';
import {
  BOOKMARKED_STATUSES_FETCH_REQUEST,
  BOOKMARKED_STATUSES_FETCH_SUCCESS,
  BOOKMARKED_STATUSES_EXPAND_SUCCESS,
  bookmarksListKey,
  bookmarksQueryKey,
} from '../../actions/bookmarks';
import {
  FAVOURITED_STATUSES_FETCH_REQUEST,
  FAVOURITED_STATUSES_FETCH_SUCCESS,
  favouritesListKey,
  favouritesQueryKey,
} from '../../actions/favourites';
import { BOOKMARK_SUCCESS, UNBOOKMARK_SUCCESS } from '../../actions/interactions';
import { COLUMN_REMOVE } from '../../actions/columns';

const request = (type, listKey, queryKey, sortByPostDate = false) => ({
  type,
  listKey,
  queryKey,
  sortByPostDate,
});

const success = (type, listKey, queryKey, ids, next = null) => ({
  type,
  listKey,
  queryKey,
  statuses: ids.map(id => ({ id })),
  next,
});

describe('saved timeline sort and cursor isolation', () => {
  it('keeps pinned columns separate and ignores a late response from the prior order', () => {
    const columnA = bookmarksListKey('column-a');
    const columnB = bookmarksListKey('column-b');
    let state = reducer(undefined, request(BOOKMARKED_STATUSES_FETCH_REQUEST, columnA, 'added'));
    state = reducer(state, success(BOOKMARKED_STATUSES_FETCH_SUCCESS, columnA, 'added', ['old-new'], '/added-next'));
    state = reducer(state, request(BOOKMARKED_STATUSES_FETCH_REQUEST, columnB, 'date', true));
    state = reducer(state, success(BOOKMARKED_STATUSES_FETCH_SUCCESS, columnB, 'date', ['new-old'], '/date-next'));
    state = reducer(state, request(BOOKMARKED_STATUSES_FETCH_REQUEST, columnA, 'new-date', true));
    state = reducer(state, success(BOOKMARKED_STATUSES_FETCH_SUCCESS, columnA, 'added', ['stale'], '/stale'));
    state = reducer(state, success(BOOKMARKED_STATUSES_FETCH_SUCCESS, columnA, 'new-date', ['new-old'], '/new-date-next'));

    expect(state.getIn([columnA, 'items']).toJS()).toEqual(['new-old']);
    expect(state.getIn([columnA, 'next'])).toBe('/new-date-next');
    expect(state.getIn([columnB, 'items']).toJS()).toEqual(['new-old']);
    expect(state.getIn([columnB, 'next'])).toBe('/date-next');
  });

  it('ignores a delayed A response after an A-B-A filter sequence', () => {
    const key = bookmarksListKey('column-a');
    let state = reducer(undefined, {
      type: BOOKMARKED_STATUSES_FETCH_REQUEST, listKey: key, queryKey: 'added', requestId: 11,
    });
    state = reducer(state, {
      type: BOOKMARKED_STATUSES_FETCH_REQUEST, listKey: key, queryKey: 'status', sortByPostDate: true, requestId: 12,
    });
    state = reducer(state, {
      type: BOOKMARKED_STATUSES_FETCH_REQUEST, listKey: key, queryKey: 'added', requestId: 13,
    });
    state = reducer(state, {
      type: BOOKMARKED_STATUSES_FETCH_SUCCESS, listKey: key, queryKey: 'added', requestId: 11,
      statuses: [{ id: 'old-result' }], next: '/wrong-page',
    });

    expect(state.getIn([key, 'items']).toJS()).toEqual([]);
    expect(state.getIn([key, 'isLoading'])).toBe(true);

    state = reducer(state, {
      type: BOOKMARKED_STATUSES_FETCH_SUCCESS, listKey: key, queryKey: 'added', requestId: 13,
      statuses: [{ id: 'new-result' }], next: '/new-page',
    });
    expect(state.getIn([key, 'items']).toJS()).toEqual(['new-result']);
    expect(state.getIn([key, 'next'])).toBe('/new-page');
  });

  it('ignores an old pagination response when the sort has changed', () => {
    const key = bookmarksListKey('column-a');
    let state = reducer(undefined, request(BOOKMARKED_STATUSES_FETCH_REQUEST, key, 'added'));
    state = reducer(state, success(BOOKMARKED_STATUSES_FETCH_SUCCESS, key, 'added', ['a'], '/added-next'));
    state = reducer(state, request(BOOKMARKED_STATUSES_FETCH_REQUEST, key, 'date', true));
    state = reducer(state, success(BOOKMARKED_STATUSES_EXPAND_SUCCESS, key, 'added', ['obsolete'], null));

    expect(state.getIn([key, 'items']).toJS()).toEqual([]);
    expect(state.getIn([key, 'queryKey'])).toBe('date');
    expect(state.getIn([key, 'isLoading'])).toBe(true);
  });

  it('keeps the default optimistic order and invalidates pinned/date views on changes', () => {
    const pinned = bookmarksListKey('column-a');
    let state = reducer(undefined, request(BOOKMARKED_STATUSES_FETCH_REQUEST, pinned, 'date', true));
    state = reducer(state, success(BOOKMARKED_STATUSES_FETCH_SUCCESS, pinned, 'date', ['123', '122']));

    state = reducer(state, { type: BOOKMARK_SUCCESS, status: fromJS({ id: '90' }) });

    expect(state.getIn(['bookmarks', 'items']).toJS()).toEqual(['90']);
    expect(state.getIn([pinned, 'items']).toJS()).toEqual(['123', '122']);
    expect(state.getIn([pinned, 'stale'])).toBe(true);

    state = reducer(state, { type: UNBOOKMARK_SUCCESS, status: fromJS({ id: '90' }) });

    expect(state.getIn(['bookmarks', 'items']).toJS()).toEqual([]);
    expect(state.getIn([pinned, 'stale'])).toBe(true);
  });

  it('does not drop a mid-fetch invalidation when a response finishes', () => {
    const key = bookmarksListKey('column-a');
    let state = reducer(undefined, request(BOOKMARKED_STATUSES_FETCH_REQUEST, key, 'date', true));
    state = reducer(state, { type: BOOKMARK_SUCCESS, status: fromJS({ id: '99' }) });
    state = reducer(state, success(BOOKMARKED_STATUSES_FETCH_SUCCESS, key, 'date', ['98']));

    expect(state.getIn([key, 'stale'])).toBe(true);
    expect(state.getIn([key, 'isLoading'])).toBe(false);
  });

  it('removes only the unpinned column state', () => {
    const a = bookmarksListKey('column-a');
    const b = bookmarksListKey('column-b');
    let state = reducer(undefined, request(BOOKMARKED_STATUSES_FETCH_REQUEST, a, 'added'));
    state = reducer(state, request(BOOKMARKED_STATUSES_FETCH_REQUEST, b, 'date', true));
    state = reducer(state, { type: COLUMN_REMOVE, uuid: 'column-a' });

    expect(state.has(a)).toBe(false);
    expect(state.has(b)).toBe(true);
  });

  it('uses independent cursors for favourites as well', () => {
    const a = favouritesListKey('col-a');
    const b = favouritesListKey('col-b');
    let state = reducer(undefined, request(FAVOURITED_STATUSES_FETCH_REQUEST, a, 'added'));
    state = reducer(state, success(FAVOURITED_STATUSES_FETCH_SUCCESS, a, 'added', ['1'], '/a-next'));
    state = reducer(state, request(FAVOURITED_STATUSES_FETCH_REQUEST, b, 'date', true));
    state = reducer(state, success(FAVOURITED_STATUSES_FETCH_SUCCESS, b, 'date', ['2'], '/b-next'));

    expect(state.getIn([a, 'items']).toJS()).toEqual(['1']);
    expect(state.getIn([b, 'items']).toJS()).toEqual(['2']);
  });

  it('distinguishes saved-query modes without affecting standalone added order', () => {
    expect(bookmarksListKey(null, false)).toBe('bookmarks');
    expect(bookmarksListKey(null, true)).toBe('bookmarks:status');
    expect(favouritesListKey(null, false)).toBe('favourites');
    expect(favouritesListKey(null, true)).toBe('favourites:status');
    expect(bookmarksQueryKey({ sortByPostDate: false })).not.toBe(bookmarksQueryKey({ sortByPostDate: true }));
    expect(favouritesQueryKey({ onlyMedia: false })).not.toBe(favouritesQueryKey({ onlyMedia: true }));
  });
});
