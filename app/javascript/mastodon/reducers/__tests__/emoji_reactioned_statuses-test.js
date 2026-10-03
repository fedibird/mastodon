jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS, List as ImmutableList } from 'immutable';
import reducer from '../emoji_reactioned_statuses';
import {
  EMOJI_REACTIONED_STATUSES_FETCH_REQUEST,
  EMOJI_REACTIONED_STATUSES_FETCH_SUCCESS,
  EMOJI_REACTIONED_STATUSES_FETCH_FAIL,
  EMOJI_REACTIONED_STATUSES_EXPAND_REQUEST,
  EMOJI_REACTIONED_STATUSES_EXPAND_SUCCESS,
  EMOJI_REACTION_EMOJIS_FETCH_REQUEST,
  EMOJI_REACTION_EMOJIS_FETCH_SUCCESS,
  EMOJI_REACTION_EMOJIS_FETCH_FAIL,
} from '../../actions/emoji_reactions';
import { COLUMN_REMOVE } from '../../actions/columns';
import { EMOJI_REACTION_SUCCESS, UN_EMOJI_REACTION_SUCCESS } from '../../actions/interactions';

const request = (listKey, queryKey, emojis = []) => ({
  type: EMOJI_REACTIONED_STATUSES_FETCH_REQUEST,
  listKey,
  queryKey,
  filters: { emojis, onlyMedia: false, withoutMedia: false },
});

const succeed = (listKey, queryKey, ids, next = null) => ({
  type: EMOJI_REACTIONED_STATUSES_FETCH_SUCCESS,
  listKey,
  queryKey,
  statuses: ids.map(id => ({ id })),
  next,
});

describe('emoji_reactioned_statuses reducer', () => {
  it('keeps default, column-a, and column-b lists independent', () => {
    let state = reducer(undefined, request('default', 'all'));
    state = reducer(state, succeed('default', 'all', ['home-1'], '/next-home'));
    state = reducer(state, request('column-a', 'party'));
    state = reducer(state, succeed('column-a', 'party', ['a-1'], '/next-a'));
    state = reducer(state, request('column-b', 'heart'));
    state = reducer(state, {
      type: EMOJI_REACTIONED_STATUSES_FETCH_SUCCESS,
      listKey: 'column-a',
      queryKey: 'party',
      statuses: [{ id: 'a-replaced' }],
      next: '/next-a2',
    });

    expect(state.getIn(['lists', 'default', 'items']).toJS()).toEqual(['home-1']);
    expect(state.getIn(['lists', 'default', 'next'])).toBe('/next-home');
    expect(state.getIn(['lists', 'default', 'isLoading'])).toBe(false);
    expect(state.getIn(['lists', 'column-a', 'items']).toJS()).toEqual(['a-replaced']);
    expect(state.getIn(['lists', 'column-a', 'next'])).toBe('/next-a2');
    expect(state.getIn(['lists', 'column-b', 'items']).toJS()).toEqual([]);
    expect(state.getIn(['lists', 'column-b', 'isLoading'])).toBe(true);
    expect(state.getIn(['lists', 'column-b', 'queryKey'])).toBe('heart');
  });

  it('ignores a late success from the previous filter', () => {
    let state = reducer(undefined, request('default', 'query-a', ['👍']));
    state = reducer(state, request('default', 'query-b', ['🎉']));
    state = reducer(state, succeed('default', 'query-b', ['b-1'], '/next-b'));
    state = reducer(state, succeed('default', 'query-a', ['a-1'], '/next-a'));

    expect(state.getIn(['lists', 'default', 'items']).toJS()).toEqual(['b-1']);
    expect(state.getIn(['lists', 'default', 'next'])).toBe('/next-b');
    expect(state.getIn(['lists', 'default', 'queryKey'])).toBe('query-b');
    expect(state.getIn(['lists', 'default', 'filters', 'emojis']).toJS()).toEqual(['🎉']);
    expect(state.getIn(['lists', 'default', 'loaded'])).toBe(true);
    expect(state.getIn(['lists', 'default', 'isLoading'])).toBe(false);
  });

  it('appends one column page without duplicating status ids or touching another column', () => {
    let state = reducer(undefined, request('column-a', 'party', ['🎉']));
    state = reducer(state, succeed('column-a', 'party', ['a-1', 'a-2'], '/next-a'));
    state = reducer(state, request('column-b', 'heart', ['❤️']));
    state = reducer(state, succeed('column-b', 'heart', ['b-1'], null));
    const beforeB = state.getIn(['lists', 'column-b']);

    state = reducer(state, {
      type: EMOJI_REACTIONED_STATUSES_EXPAND_REQUEST,
      listKey: 'column-a',
      queryKey: 'party',
    });
    state = reducer(state, {
      type: EMOJI_REACTIONED_STATUSES_EXPAND_SUCCESS,
      listKey: 'column-a',
      queryKey: 'party',
      statuses: [{ id: 'a-2' }, { id: 'a-3' }],
      next: null,
    });

    expect(state.getIn(['lists', 'column-a', 'items']).toJS()).toEqual(['a-1', 'a-2', 'a-3']);
    expect(state.get('lists').get('column-b')).toBe(beforeB);
  });

  it('drops only the removed column list', () => {
    let state = reducer(undefined, request('default', 'all'));
    state = reducer(state, succeed('default', 'all', ['home-1']));
    state = reducer(state, request('column-a', 'party'));
    state = reducer(state, succeed('column-a', 'party', ['a-1']));
    state = reducer(state, request('column-b', 'heart'));
    state = reducer(state, succeed('column-b', 'heart', ['b-1']));

    state = reducer(state, { type: COLUMN_REMOVE, uuid: 'column-a' });

    expect(state.getIn(['lists', 'column-a'])).toBeUndefined();
    expect(state.getIn(['lists', 'default', 'items']).toJS()).toEqual(['home-1']);
    expect(state.getIn(['lists', 'column-b', 'items']).toJS()).toEqual(['b-1']);
  });

  it.each([
    EMOJI_REACTION_SUCCESS,
    UN_EMOJI_REACTION_SUCCESS,
  ])('marks every list stale without changing membership for %s', type => {
    let state = reducer(undefined, request('default', 'all'));
    state = reducer(state, succeed('default', 'all', ['home-1']));
    state = reducer(state, request('column-a', 'party'));
    state = reducer(state, succeed('column-a', 'party', ['a-1']));

    state = reducer(state, {
      type,
      status: fromJS({ id: 'new-status' }),
    });

    expect(state.getIn(['lists', 'default', 'stale'])).toBe(true);
    expect(state.getIn(['lists', 'column-a', 'stale'])).toBe(true);
    expect(state.getIn(['lists', 'default', 'items']).toJS()).toEqual(['home-1']);
    expect(state.getIn(['lists', 'column-a', 'items']).toJS()).toEqual(['a-1']);
    expect(state.getIn(['catalog', 'stale'])).toBe(true);
    expect(state.getIn(['catalog', 'loaded'])).toBe(false);
  });

  it('keeps stale true when an in-flight fetch succeeds after a reaction', () => {
    let state = reducer(undefined, request('default', 'all'));
    expect(state.getIn(['lists', 'default', 'stale'])).toBe(false);

    state = reducer(state, { type: EMOJI_REACTION_SUCCESS, status: fromJS({ id: '1' }) });
    expect(state.getIn(['lists', 'default', 'stale'])).toBe(true);

    state = reducer(state, succeed('default', 'all', ['home-1']));
    expect(state.getIn(['lists', 'default', 'items']).toJS()).toEqual(['home-1']);
    expect(state.getIn(['lists', 'default', 'isLoading'])).toBe(false);
    expect(state.getIn(['lists', 'default', 'stale'])).toBe(true);
  });

  it('ignores an expand success after the filter changes', () => {
    let state = reducer(undefined, request('default', 'query-a', ['👍']));
    state = reducer(state, succeed('default', 'query-a', ['a-1'], '/next-a'));
    state = reducer(state, request('default', 'query-b', ['🎉']));

    state = reducer(state, {
      type: EMOJI_REACTIONED_STATUSES_EXPAND_SUCCESS,
      listKey: 'default',
      queryKey: 'query-a',
      statuses: [{ id: 'old-page' }],
      next: null,
    });

    expect(state.getIn(['lists', 'default', 'items']).toJS()).toEqual([]);
    expect(state.getIn(['lists', 'default', 'queryKey'])).toBe('query-b');
    expect(state.getIn(['lists', 'default', 'isLoading'])).toBe(true);
  });

  it('does not let a stale failure clear loading for the current query', () => {
    let state = reducer(undefined, request('default', 'query-b', ['🎉']));
    state = reducer(state, {
      type: EMOJI_REACTIONED_STATUSES_FETCH_FAIL,
      listKey: 'default',
      queryKey: 'query-a',
      error: new Error('late'),
    });

    expect(state.getIn(['lists', 'default', 'isLoading'])).toBe(true);
    expect(state.getIn(['lists', 'default', 'queryKey'])).toBe('query-b');
  });

  describe('catalog', () => {
    it('starts empty', () => {
      const state = reducer(undefined, { type: '@@INIT' });

      expect(state.getIn(['catalog', 'items'])).toEqual(ImmutableList());
      expect(state.getIn(['catalog', 'loaded'])).toBe(false);
      expect(state.getIn(['catalog', 'isLoading'])).toBe(false);
      expect(state.getIn(['catalog', 'stale'])).toBe(false);
      expect(state.getIn(['catalog', 'error'])).toBeNull();
    });

    it('stores catalog items in API order and keeps them after a failure', () => {
      let state = reducer(undefined, { type: EMOJI_REACTION_EMOJIS_FETCH_REQUEST });
      expect(state.getIn(['catalog', 'isLoading'])).toBe(true);
      expect(state.getIn(['catalog', 'error'])).toBeNull();

      state = reducer(state, {
        type: EMOJI_REACTION_EMOJIS_FETCH_SUCCESS,
        emojis: [
          { name: '🎉', domain: null, custom: false, count: 3 },
          { name: 'great', domain: 'example.com', custom: true, count: 1 },
        ],
      });

      expect(state.getIn(['catalog', 'items']).map(item => item.get('name')).toJS()).toEqual(['🎉', 'great']);
      expect(state.getIn(['catalog', 'items', 1, 'domain'])).toBe('example.com');
      expect(state.getIn(['catalog', 'loaded'])).toBe(true);
      expect(state.getIn(['catalog', 'isLoading'])).toBe(false);
      expect(state.getIn(['catalog', 'stale'])).toBe(false);

      state = reducer(state, {
        type: EMOJI_REACTION_EMOJIS_FETCH_FAIL,
        error: 'unavailable',
      });

      expect(state.getIn(['catalog', 'items']).map(item => item.get('name')).toJS()).toEqual(['🎉', 'great']);
      expect(state.getIn(['catalog', 'isLoading'])).toBe(false);
      expect(state.getIn(['catalog', 'error'])).toBe('unavailable');
      expect(state.getIn(['catalog', 'loaded'])).toBe(true);
    });
  });
});
