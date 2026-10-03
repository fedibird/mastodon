import {
  EMOJI_REACTIONED_STATUSES_FETCH_REQUEST,
  EMOJI_REACTIONED_STATUSES_FETCH_SUCCESS,
  EMOJI_REACTIONED_STATUSES_FETCH_FAIL,
  EMOJI_REACTIONED_STATUSES_EXPAND_REQUEST,
  EMOJI_REACTIONED_STATUSES_EXPAND_SUCCESS,
  EMOJI_REACTIONED_STATUSES_EXPAND_FAIL,
  EMOJI_REACTION_EMOJIS_FETCH_REQUEST,
  EMOJI_REACTION_EMOJIS_FETCH_SUCCESS,
  EMOJI_REACTION_EMOJIS_FETCH_FAIL,
  DEFAULT_EMOJI_REACTIONED_STATUSES_LIST_KEY,
} from '../actions/emoji_reactions';
import { COLUMN_REMOVE } from '../actions/columns';
import { EMOJI_REACTION_SUCCESS, UN_EMOJI_REACTION_SUCCESS } from '../actions/interactions';
import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';

const createFilters = (filters = {}) => ImmutableMap({
  emojis: ImmutableList(filters.emojis || []),
  onlyMedia: !!filters.onlyMedia,
  withoutMedia: !!filters.withoutMedia,
});

const createList = () => ImmutableMap({
  items: ImmutableList(),
  next: null,
  loaded: false,
  isLoading: false,
  stale: false,
  queryKey: null,
  filters: createFilters(),
});

const createCatalog = () => ImmutableMap({
  items: ImmutableList(),
  loaded: false,
  isLoading: false,
  stale: false,
  error: null,
});

const initialState = ImmutableMap({
  lists: ImmutableMap({
    [DEFAULT_EMOJI_REACTIONED_STATUSES_LIST_KEY]: createList(),
  }),
  catalog: createCatalog(),
});

const listFor = (state, listKey) => state.getIn(['lists', listKey]);

const matchesQuery = (state, action) => {
  const list = listFor(state, action.listKey);
  return !!(list && list.get('queryKey') === action.queryKey);
};

const statusIds = statuses => ImmutableList((statuses || []).map(status => status.id));

const appendUniqueIds = (items, statuses) => {
  const seen = new Set(items.toArray());
  const appended = [];

  (statuses || []).forEach(status => {
    if (seen.has(status.id)) {
      return;
    }

    seen.add(status.id);
    appended.push(status.id);
  });

  return items.concat(appended);
};

const markReactionListsStale = state => state.withMutations(map => {
  map.update('lists', lists => lists.map(list => list.set('stale', true)));
  map.setIn(['catalog', 'stale'], true);
  map.setIn(['catalog', 'loaded'], false);
});

export default function emojiReactionedStatuses(state = initialState, action) {
  switch (action.type) {
  case EMOJI_REACTIONED_STATUSES_FETCH_REQUEST:
    return state.updateIn(['lists', action.listKey], createList(), list => list.merge({
      queryKey: action.queryKey,
      filters: createFilters(action.filters),
      isLoading: true,
      loaded: false,
      next: null,
      items: ImmutableList(),
      stale: false,
    }));
  case EMOJI_REACTIONED_STATUSES_FETCH_SUCCESS:
    if (!matchesQuery(state, action)) {
      return state;
    }

    return state.mergeIn(['lists', action.listKey], {
      next: action.next,
      loaded: true,
      isLoading: false,
      items: statusIds(action.statuses),
    });
  case EMOJI_REACTIONED_STATUSES_FETCH_FAIL:
    if (!matchesQuery(state, action)) {
      return state;
    }

    return state.setIn(['lists', action.listKey, 'isLoading'], false);
  case EMOJI_REACTIONED_STATUSES_EXPAND_REQUEST:
    if (!matchesQuery(state, action)) {
      return state;
    }

    return state.setIn(['lists', action.listKey, 'isLoading'], true);
  case EMOJI_REACTIONED_STATUSES_EXPAND_SUCCESS:
    if (!matchesQuery(state, action)) {
      return state;
    }

    return state.updateIn(['lists', action.listKey], list => list.merge({
      next: action.next,
      isLoading: false,
      items: appendUniqueIds(list.get('items'), action.statuses),
    }));
  case EMOJI_REACTIONED_STATUSES_EXPAND_FAIL:
    if (!matchesQuery(state, action)) {
      return state;
    }

    return state.setIn(['lists', action.listKey, 'isLoading'], false);
  case EMOJI_REACTION_EMOJIS_FETCH_REQUEST:
    return state.mergeIn(['catalog'], {
      isLoading: true,
      error: null,
    });
  case EMOJI_REACTION_EMOJIS_FETCH_SUCCESS:
    return state.mergeIn(['catalog'], {
      items: fromJS(action.emojis || []),
      loaded: true,
      isLoading: false,
      stale: false,
      error: null,
    });
  case EMOJI_REACTION_EMOJIS_FETCH_FAIL:
    return state.mergeIn(['catalog'], {
      isLoading: false,
      error: action.error,
    });
  case EMOJI_REACTION_SUCCESS:
  case UN_EMOJI_REACTION_SUCCESS:
    return markReactionListsStale(state);
  case COLUMN_REMOVE:
    if (!action.uuid || action.uuid === DEFAULT_EMOJI_REACTIONED_STATUSES_LIST_KEY) {
      return state;
    }

    return state.deleteIn(['lists', action.uuid]);
  default:
    return state;
  }
}
