import { fromJS } from 'immutable';

jest.mock('../../actions/statuses', () => ({
  STATUS_MUTE_SUCCESS: 'STATUS_MUTE_SUCCESS',
  STATUS_UNMUTE_SUCCESS: 'STATUS_UNMUTE_SUCCESS',
  STATUS_REVEAL: 'STATUS_REVEAL',
  STATUS_HIDE: 'STATUS_HIDE',
  STATUS_COLLAPSE: 'STATUS_COLLAPSE',
}));

import {
  UNFAVOURITE_FAIL,
  UNFAVOURITE_REQUEST,
  UNFAVOURITE_SUCCESS,
  UNREBLOG_FAIL,
  UNREBLOG_REQUEST,
} from '../../actions/interactions';
import statuses from '../statuses';

const status = fromJS({
  id: '1',
  favourited: true,
  favourites_count: 2,
  reblogged: true,
  reblogs_count: 3,
});

describe('statuses unfavourite and unreblog', () => {
  it('clears favourited immediately and restores it when the request fails', () => {
    const requested = statuses(fromJS({ 1: status }), {
      type: UNFAVOURITE_REQUEST,
      status,
    });

    expect(requested.getIn(['1', 'favourited'])).toBe(false);
    expect(requested.getIn(['1', 'favourites_count'])).toBe(2);

    const failed = statuses(requested, {
      type: UNFAVOURITE_FAIL,
      status,
    });

    expect(failed.getIn(['1', 'favourited'])).toBe(true);
    expect(failed.getIn(['1', 'favourites_count'])).toBe(2);
  });

  it('does not decrement favourites_count again when unfavourite succeeds', () => {
    const state = fromJS({ 1: status.set('favourited', false) });

    const next = statuses(state, {
      type: UNFAVOURITE_SUCCESS,
      status,
    });

    expect(next).toBe(state);
    expect(next.getIn(['1', 'favourites_count'])).toBe(2);
  });

  it('clears reblogged immediately and restores it when the request fails', () => {
    const requested = statuses(fromJS({ 1: status }), {
      type: UNREBLOG_REQUEST,
      status,
    });

    expect(requested.getIn(['1', 'reblogged'])).toBe(false);
    expect(requested.getIn(['1', 'reblogs_count'])).toBe(3);

    const failed = statuses(requested, {
      type: UNREBLOG_FAIL,
      status,
    });

    expect(failed.getIn(['1', 'reblogged'])).toBe(true);
    expect(failed.getIn(['1', 'reblogs_count'])).toBe(3);
  });

  it('leaves state unchanged when the status is absent', () => {
    const state = fromJS({});

    expect(statuses(state, { type: UNFAVOURITE_REQUEST, status })).toBe(state);
    expect(statuses(state, { type: UNFAVOURITE_FAIL, status })).toBe(state);
    expect(statuses(state, { type: UNREBLOG_REQUEST, status })).toBe(state);
    expect(statuses(state, { type: UNREBLOG_FAIL, status })).toBe(state);
  });
});
