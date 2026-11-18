import {
  FAVOURITED_STATUSES_FETCH_REQUEST,
  FAVOURITED_STATUSES_FETCH_SUCCESS,
  FAVOURITED_STATUSES_FETCH_FAIL,
  FAVOURITED_STATUSES_EXPAND_REQUEST,
  FAVOURITED_STATUSES_EXPAND_SUCCESS,
  FAVOURITED_STATUSES_EXPAND_FAIL,
} from '../actions/favourites';
import {
  BOOKMARKED_STATUSES_FETCH_REQUEST,
  BOOKMARKED_STATUSES_FETCH_SUCCESS,
  BOOKMARKED_STATUSES_FETCH_FAIL,
  BOOKMARKED_STATUSES_EXPAND_REQUEST,
  BOOKMARKED_STATUSES_EXPAND_SUCCESS,
  BOOKMARKED_STATUSES_EXPAND_FAIL,
} from '../actions/bookmarks';
import { PINNED_STATUSES_FETCH_SUCCESS } from '../actions/pin_statuses';
import { ACCOUNT_BLOCK_SUCCESS, ACCOUNT_MUTE_SUCCESS } from '../actions/accounts';
import {
  TRENDS_STATUSES_FETCH_REQUEST,
  TRENDS_STATUSES_FETCH_SUCCESS,
  TRENDS_STATUSES_FETCH_FAIL,
  TRENDS_STATUSES_EXPAND_REQUEST,
  TRENDS_STATUSES_EXPAND_SUCCESS,
  TRENDS_STATUSES_EXPAND_FAIL,
} from '../actions/trends';
import { COLUMN_REMOVE } from '../actions/columns';
import { Map as ImmutableMap, List as ImmutableList } from 'immutable';
import {
  FAVOURITE_SUCCESS,
  UNFAVOURITE_SUCCESS,
  BOOKMARK_SUCCESS,
  UNBOOKMARK_SUCCESS,
  PIN_SUCCESS,
  UNPIN_SUCCESS,
} from '../actions/interactions';

const createList = () => ImmutableMap({
  next: null,
  loaded: false,
  isLoading: false,
  stale: false,
  sortByPostDate: false,
  queryKey: null,
  items: ImmutableList(),
});

const initialState = ImmutableMap({
  favourites: createList(),
  bookmarks: createList(),
  pins: createList(),
  trending: createList(),
});

const listKeyOf = (action, fallback) => action.listKey || fallback;

// A superseded request must never replace the next-page cursor of a newer
// filter/order, including when the user flips the order twice quickly.
const matchesQuery = (state, action, listKey) => (
  state.has(listKey) && (action.queryKey === null || action.queryKey === undefined || state.getIn([listKey, 'queryKey']) === action.queryKey)
);

const beginFetch = (state, listKey, action) => state.update(listKey, createList(), list => list.merge({
  next: null,
  loaded: false,
  isLoading: true,
  stale: false,
  sortByPostDate: !!action.sortByPostDate,
  queryKey: action.queryKey,
  items: ImmutableList(),
}));

const normalizeList = (state, listKey, statuses, next) => state.update(listKey, createList(), list => list.withMutations(map => {
  map.set('next', next);
  map.set('loaded', true);
  map.set('isLoading', false);
  map.set('items', ImmutableList(statuses.map(item => item.id)));
}));

const appendToList = (state, listKey, statuses, next) => state.update(listKey, createList(), list => list.withMutations(map => {
  map.set('next', next);
  map.set('isLoading', false);
  map.set('items', map.get('items').concat(statuses.map(item => item.id)));
}));

const itemExists = (state, listKey, status) => (
  state.getIn([listKey, 'items']).findIndex(item => item === status.get('id')) > -1
);

const prependOneToList = (state, listKey, status) => {
  if (!itemExists(state, listKey, status)) {
    return state.updateIn([listKey, 'items'], items => items.unshift(status.get('id')));
  }

  return state;
};

const removeOneFromList = (state, listKey, status) => (
  state.updateIn([listKey, 'items'], items => items.filter(item => item !== status.get('id')))
);

// For pinned columns (and the standalone status-ordered view), reload after
// an action. A new bookmark/favourite may be anywhere in post-date order and
// cannot safely be prepended without invalidating the server page boundary.
// Leave the existing default-list optimistic update intact.
const markCopiesStale = (state, prefix) => state.withMutations(map => {
  state.keySeq().forEach(key => {
    if (key.startsWith(`${prefix}:`)) {
      map.setIn([key, 'stale'], true);
    }
  });
});

export default function statusLists(state = initialState, action) {
  let listKey;

  switch (action.type) {
  case FAVOURITED_STATUSES_FETCH_REQUEST:
    return beginFetch(state, listKeyOf(action, 'favourites'), action);
  case FAVOURITED_STATUSES_EXPAND_REQUEST:
    listKey = listKeyOf(action, 'favourites');
    return matchesQuery(state, action, listKey) ? state.setIn([listKey, 'isLoading'], true) : state;
  case FAVOURITED_STATUSES_FETCH_FAIL:
  case FAVOURITED_STATUSES_EXPAND_FAIL:
    listKey = listKeyOf(action, 'favourites');
    return matchesQuery(state, action, listKey) ? state.setIn([listKey, 'isLoading'], false) : state;
  case FAVOURITED_STATUSES_FETCH_SUCCESS:
    listKey = listKeyOf(action, 'favourites');
    return matchesQuery(state, action, listKey) ? normalizeList(state, listKey, action.statuses, action.next) : state;
  case FAVOURITED_STATUSES_EXPAND_SUCCESS:
    listKey = listKeyOf(action, 'favourites');
    return matchesQuery(state, action, listKey) ? appendToList(state, listKey, action.statuses, action.next) : state;

  case BOOKMARKED_STATUSES_FETCH_REQUEST:
    return beginFetch(state, listKeyOf(action, 'bookmarks'), action);
  case BOOKMARKED_STATUSES_EXPAND_REQUEST:
    listKey = listKeyOf(action, 'bookmarks');
    return matchesQuery(state, action, listKey) ? state.setIn([listKey, 'isLoading'], true) : state;
  case BOOKMARKED_STATUSES_FETCH_FAIL:
  case BOOKMARKED_STATUSES_EXPAND_FAIL:
    listKey = listKeyOf(action, 'bookmarks');
    return matchesQuery(state, action, listKey) ? state.setIn([listKey, 'isLoading'], false) : state;
  case BOOKMARKED_STATUSES_FETCH_SUCCESS:
    listKey = listKeyOf(action, 'bookmarks');
    return matchesQuery(state, action, listKey) ? normalizeList(state, listKey, action.statuses, action.next) : state;
  case BOOKMARKED_STATUSES_EXPAND_SUCCESS:
    listKey = listKeyOf(action, 'bookmarks');
    return matchesQuery(state, action, listKey) ? appendToList(state, listKey, action.statuses, action.next) : state;

  case TRENDS_STATUSES_FETCH_REQUEST:
  case TRENDS_STATUSES_EXPAND_REQUEST:
    return state.setIn(['trending', 'isLoading'], true);
  case TRENDS_STATUSES_FETCH_FAIL:
  case TRENDS_STATUSES_EXPAND_FAIL:
    return state.setIn(['trending', 'isLoading'], false);
  case TRENDS_STATUSES_FETCH_SUCCESS:
    return normalizeList(state, 'trending', action.statuses, action.next);
  case TRENDS_STATUSES_EXPAND_SUCCESS:
    return appendToList(state, 'trending', action.statuses, action.next);

  case FAVOURITE_SUCCESS:
    return markCopiesStale(prependOneToList(state, 'favourites', action.status), 'favourites');
  case UNFAVOURITE_SUCCESS:
    return markCopiesStale(removeOneFromList(state, 'favourites', action.status), 'favourites');
  case BOOKMARK_SUCCESS:
    return markCopiesStale(prependOneToList(state, 'bookmarks', action.status), 'bookmarks');
  case UNBOOKMARK_SUCCESS:
    return markCopiesStale(removeOneFromList(state, 'bookmarks', action.status), 'bookmarks');
  case PINNED_STATUSES_FETCH_SUCCESS:
    return normalizeList(state, 'pins', action.statuses, action.next);
  case PIN_SUCCESS:
    return prependOneToList(state, 'pins', action.status);
  case UNPIN_SUCCESS:
    return removeOneFromList(state, 'pins', action.status);
  case ACCOUNT_BLOCK_SUCCESS:
  case ACCOUNT_MUTE_SUCCESS:
    return state.updateIn(
      ['trending', 'items'],
      ImmutableList(),
      list => list.filterNot(statusId => action.statuses.getIn([statusId, 'account']) === action.relationship.id),
    );
  case COLUMN_REMOVE:
    return action.uuid ? state.delete(`bookmarks:${action.uuid}`).delete(`favourites:${action.uuid}`) : state;
  default:
    return state;
  }
}
