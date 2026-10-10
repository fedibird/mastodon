jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS, Map as ImmutableMap } from 'immutable';
import reducer from '../mix_timelines';
import { STORE_HYDRATE } from '../../actions/store';
import { ACCOUNT_BLOCK_SUCCESS } from '../../actions/accounts';
import {
  MIX_TIMELINE_OPEN,
  MIX_SOURCE_SUCCESS,
  MIX_SOURCE_FAIL,
} from '../../actions/mix_timelines';

const open = (columnKey, keys) => ({
  type: MIX_TIMELINE_OPEN,
  columnKey,
  mixId: 'mix-1',
  definitionFingerprint: keys.join('\n'),
  sessionId: 1,
  sources: keys.map(key => ({ key, descriptor: { type: 'public', params: {} } })),
});

describe('mix timeline state', () => {
  it('keeps cursors independent for the same source in two columns', () => {
    let state = reducer(undefined, open('column:one', ['src']));
    state = reducer(state, open('column:two', ['src']));
    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:one',
      sourceKey: 'src',
      sessionId: 1,
      definitionFingerprint: 'src',
      ids: ['500', '400'],
      cursor: '400',
      frontier: '400',
      hasMore: true,
    });

    expect(state.getIn(['column:one', 'sources', 'src', 'ids']).toArray()).toEqual(['500', '400']);
    expect(state.getIn(['column:two', 'sources', 'src', 'ids']).toArray()).toEqual([]);
    expect(state.getIn(['column:one', 'sources', 'src', 'cursor'])).toBe('400');
    expect(state.getIn(['column:two', 'sources', 'src', 'hasMore'])).toBe(true);
  });

  it('ignores a stale page and clears a forbidden source', () => {
    let state = reducer(undefined, open('route:mix-1', ['src']));

    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'route:mix-1',
      sourceKey: 'src',
      sessionId: 1,
      definitionFingerprint: 'src',
      ids: ['500'],
      cursor: '500',
      frontier: '500',
      hasMore: true,
      filterResults: { '500': [{ filter: 'home-filter' }] },
    });
    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'route:mix-1',
      sourceKey: 'src',
      sessionId: 0,
      definitionFingerprint: 'src',
      ids: ['100'],
      cursor: null,
      frontier: '100',
      hasMore: false,
    });
    state = reducer(state, {
      type: MIX_SOURCE_FAIL,
      columnKey: 'route:mix-1',
      sourceKey: 'src',
      sessionId: 1,
      definitionFingerprint: 'old',
      error: 'server',
      clear: false,
    });
    state = reducer(state, {
      type: MIX_SOURCE_FAIL,
      columnKey: 'route:mix-1',
      sourceKey: 'src',
      sessionId: 1,
      definitionFingerprint: 'src',
      error: 'forbidden',
      clear: true,
    });

    expect(state.getIn(['route:mix-1', 'sources', 'src', 'ids']).size).toBe(0);
    expect(state.getIn(['route:mix-1', 'sources', 'src', 'error'])).toBe('forbidden');
  });

  it('drops fetch state on hydrate and removes blocked statuses', () => {
    let state = reducer(undefined, open('column:one', ['src']));

    state = reducer(state, {
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:one',
      sourceKey: 'src',
      sessionId: 1,
      definitionFingerprint: 'src',
      ids: ['500', '400'],
      cursor: null,
      frontier: '400',
      hasMore: false,
    });
    state = reducer(state, {
      type: ACCOUNT_BLOCK_SUCCESS,
      relationship: { id: '9' },
      statuses: fromJS({
        '500': { id: '500', account: '9', reblog: null },
        '400': { id: '400', account: '2', reblog: null },
      }),
    });

    expect(state.getIn(['column:one', 'sources', 'src', 'ids']).toArray()).toEqual(['400']);
    expect(reducer(state, { type: STORE_HYDRATE, state: ImmutableMap() })).toEqual(ImmutableMap());
  });
});
