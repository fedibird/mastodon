import { fromJS } from 'immutable';

import { UNBOOKMARK_FAIL, UNBOOKMARK_REQUEST } from '../../actions/interactions';
import statuses from '../statuses';

const status = fromJS({ id: '1', bookmarked: true });

describe('statuses unbookmark', () => {
  it('clears the bookmark immediately and restores it when the request fails', () => {
    const requested = statuses(fromJS({ 1: status }), {
      type: UNBOOKMARK_REQUEST,
      status,
    });

    expect(requested.getIn(['1', 'bookmarked'])).toBe(false);

    const failed = statuses(requested, {
      type: UNBOOKMARK_FAIL,
      status,
    });

    expect(failed.getIn(['1', 'bookmarked'])).toBe(true);
  });

  it('leaves state unchanged when the status is absent', () => {
    const state = fromJS({});

    expect(statuses(state, { type: UNBOOKMARK_REQUEST, status })).toBe(state);
    expect(statuses(state, { type: UNBOOKMARK_FAIL, status })).toBe(state);
  });
});
