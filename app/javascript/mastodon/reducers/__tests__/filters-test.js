import { fromJS } from 'immutable';

jest.mock('../../actions/statuses', () => ({
  fetchStatus: jest.fn(),
}));

import { FILTERS_FETCH_SUCCESS } from '../../actions/filters';
import { FILTERS_IMPORT } from '../../actions/importer';
import filters from '../filters';

describe('filters reducer', () => {
  it('stores imported filters as an ID-keyed map', () => {
    const state = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [{
        id: 1,
        title: 'spoiler',
        context: ['home'],
        filter_action: 'warn',
        expires_at: null,
      }],
    });

    expect(state.getIn(['1', 'id'])).toEqual('1');
    expect(state.getIn(['1', 'title'])).toEqual('spoiler');
    expect(state.getIn(['1', 'filter_action'])).toEqual('warn');
    expect(state.getIn(['1', 'expires_at'])).toEqual(null);
  });

  it('maps integer streaming filter_action values to warn/hide', () => {
    const state = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [{
        id: '2',
        title: 'hide me',
        context: ['home'],
        filter_action: 1,
        expires_at: null,
      }],
    });

    expect(state.getIn(['2', 'filter_action'])).toEqual('hide');
  });

  it('parses expires_at into a timestamp', () => {
    const expiresAt = '2024-01-01T00:00:00.000Z';
    const state = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [{
        id: '3',
        title: 'expired',
        context: ['home'],
        filter_action: 'warn',
        expires_at: expiresAt,
      }],
    });

    expect(state.getIn(['3', 'expires_at'])).toEqual(Date.parse(expiresAt));
  });

  it('stores keywords and statuses from a full Filters v2 payload', () => {
    const state = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [{
        id: '4',
        title: 'status filter',
        context: ['home', 'public'],
        filter_action: 'warn',
        expires_at: null,
        keywords: [{ id: 'k1', keyword: 'foo', whole_word: true }],
        statuses: [{ id: 'fs1', status_id: 's9' }],
      }],
    });

    expect(state.getIn(['4', 'keywords']).toJS()).toEqual([
      { id: 'k1', keyword: 'foo', whole_word: true },
    ]);
    expect(state.getIn(['4', 'statuses']).toJS()).toEqual([
      { id: 'fs1', status_id: 's9' },
    ]);
  });

  it('replaces the current filter collection on FILTERS_FETCH_SUCCESS', () => {
    const initial = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [
        {
          id: '1',
          title: 'deleted filter',
          context: ['home'],
          filter_action: 'warn',
          expires_at: null,
          keywords: [{ id: 'k-old', keyword: 'gone', whole_word: false }],
          statuses: [{ id: 'fs-old', status_id: 's-old' }],
        },
        {
          id: '2',
          title: 'kept filter',
          context: ['home'],
          filter_action: 'warn',
          expires_at: null,
          keywords: [{ id: 'k2', keyword: 'keepme', whole_word: true }],
          statuses: [{ id: 'fs2', status_id: 's2' }],
        },
      ],
    });

    const state = filters(initial, {
      type: FILTERS_FETCH_SUCCESS,
      filters: [{
        id: '2',
        title: 'kept filter',
        context: ['home'],
        filter_action: 'warn',
        expires_at: null,
        keywords: [{ id: 'k2', keyword: 'keepme', whole_word: true }],
        statuses: [{ id: 'fs2', status_id: 's2' }],
      }],
    });

    expect(state.has('1')).toEqual(false);
    expect(state.has('2')).toEqual(true);
    expect(state.getIn(['2', 'keywords']).toJS()).toEqual([
      { id: 'k2', keyword: 'keepme', whole_word: true },
    ]);
    expect(state.getIn(['2', 'statuses']).toJS()).toEqual([
      { id: 'fs2', status_id: 's2' },
    ]);
  });

  it('does not wipe keywords or statuses on a partial FilterResult import', () => {
    const initial = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [{
        id: '5',
        title: 'keep rules',
        context: ['home'],
        filter_action: 'warn',
        expires_at: null,
        keywords: [{ keyword: 'keepme' }],
        statuses: [{ status_id: 's1' }],
      }],
    });

    const state = filters(initial, {
      type: FILTERS_IMPORT,
      filters: [{
        id: '5',
        title: 'keep rules',
        context: ['home'],
        filter_action: 'hide',
        expires_at: null,
      }],
    });

    expect(state.getIn(['5', 'filter_action'])).toEqual('hide');
    expect(state.getIn(['5', 'keywords']).toJS()).toEqual([{ keyword: 'keepme' }]);
    expect(state.getIn(['5', 'statuses']).toJS()).toEqual([{ status_id: 's1' }]);
  });

  it('ignores incomplete filter objects', () => {
    const initial = fromJS({});
    const state = filters(initial, {
      type: FILTERS_IMPORT,
      filters: [null, {}],
    });

    expect(state).toEqual(initial);
  });
});
