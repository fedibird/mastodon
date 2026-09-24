import {
  TRENDS_STATUSES_FETCH_REQUEST,
  TRENDS_STATUSES_FETCH_SUCCESS,
  TRENDS_STATUSES_FETCH_FAIL,
  TRENDS_STATUSES_EXPAND_REQUEST,
  TRENDS_STATUSES_EXPAND_SUCCESS,
  TRENDS_STATUSES_EXPAND_FAIL,
} from '../../actions/trends';
import { ACCOUNT_BLOCK_SUCCESS, ACCOUNT_MUTE_SUCCESS } from '../../actions/accounts';
import { fromJS } from 'immutable';
import statusLists from '../status_lists';

describe('status_lists trending', () => {
  it('normalizes the first page and stores its next link', () => {
    const requested = statusLists(undefined, { type: TRENDS_STATUSES_FETCH_REQUEST });
    expect(requested.getIn(['trending', 'isLoading'])).toBe(true);

    const loaded = statusLists(requested, {
      type: TRENDS_STATUSES_FETCH_SUCCESS,
      statuses: [{ id: '1' }, { id: '2' }],
      next: '/api/v1/trends/statuses?max_id=2',
    });

    expect(loaded.getIn(['trending', 'items']).toJS()).toEqual(['1', '2']);
    expect(loaded.getIn(['trending', 'next'])).toEqual('/api/v1/trends/statuses?max_id=2');
    expect(loaded.getIn(['trending', 'isLoading'])).toBe(false);
    expect(loaded.getIn(['trending', 'loaded'])).toBe(true);
  });

  it('appends a later page and updates pagination', () => {
    const firstPage = statusLists(undefined, {
      type: TRENDS_STATUSES_FETCH_SUCCESS,
      statuses: [{ id: '1' }, { id: '2' }],
      next: '/api/v1/trends/statuses?max_id=2',
    });
    const requested = statusLists(firstPage, { type: TRENDS_STATUSES_EXPAND_REQUEST });
    expect(requested.getIn(['trending', 'isLoading'])).toBe(true);

    const expanded = statusLists(requested, {
      type: TRENDS_STATUSES_EXPAND_SUCCESS,
      statuses: [{ id: '3' }],
      next: null,
    });

    expect(expanded.getIn(['trending', 'items']).toJS()).toEqual(['1', '2', '3']);
    expect(expanded.getIn(['trending', 'next'])).toBeNull();
    expect(expanded.getIn(['trending', 'isLoading'])).toBe(false);
  });

  it.each([TRENDS_STATUSES_FETCH_FAIL, TRENDS_STATUSES_EXPAND_FAIL])('clears loading for %s', type => {
    const requested = statusLists(undefined, { type: TRENDS_STATUSES_FETCH_REQUEST });
    const failed = statusLists(requested, { type });

    expect(failed.getIn(['trending', 'isLoading'])).toBe(false);
  });

  it.each([
    ['block', ACCOUNT_BLOCK_SUCCESS],
    ['mute', ACCOUNT_MUTE_SUCCESS],
  ])('removes only the affected account after a %s', (label, type) => {
    const loaded = statusLists(undefined, {
      type: TRENDS_STATUSES_FETCH_SUCCESS,
      statuses: [{ id: 'status-a' }, { id: 'status-b' }],
      next: null,
    });

    const updated = statusLists(loaded, {
      type,
      relationship: { id: 'account-a' },
      statuses: fromJS({
        'status-a': { account: 'account-a' },
        'status-b': { account: 'account-b' },
      }),
    });

    expect(updated.getIn(['trending', 'items']).toJS()).toEqual(['status-b']);
  });
});
