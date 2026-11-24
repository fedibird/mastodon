import { Map as ImmutableMap } from 'immutable';

import api from 'mastodon/api';
import { featureUsageFlag } from 'mastodon/feature_usage';
import { fetchCircles, prefetchCircles, setupCircleAdder } from '../circles';
import { fetchLists, setupListAdder } from '../lists';

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('mastodon/feature_usage', () => ({
  featureUsageFlag: jest.fn(),
  initialFeaturePrefetchAllowed: flag => flag !== false,
}));

const state = () => ImmutableMap({
  meta: ImmutableMap({ access_token: 'token' }),
  accounts: ImmutableMap(),
});

describe('owned circle and list prefetches', () => {
  let get;

  beforeEach(() => {
    get = jest.fn(() => Promise.resolve({ data: [] }));
    api.mockReset();
    api.mockReturnValue({ get });
    featureUsageFlag.mockReset();
  });

  it('skips the boot circle request only when the document hint is false', () => {
    const dispatch = jest.fn(action => {
      if (typeof action === 'function') {
        return action(dispatch, state);
      }

      return action;
    });

    featureUsageFlag.mockReturnValue(false);
    expect(prefetchCircles()(dispatch, state)).toBeNull();
    expect(get).not.toHaveBeenCalled();
    expect(dispatch).not.toHaveBeenCalled();

    featureUsageFlag.mockReturnValue(true);
    prefetchCircles()(dispatch, state);
    expect(get).toHaveBeenCalledWith('/api/v1/circles');

    get.mockClear();
    featureUsageFlag.mockReturnValue(undefined);
    prefetchCircles()(dispatch, state);
    expect(get).toHaveBeenCalledTimes(1);
    expect(get).toHaveBeenCalledWith('/api/v1/circles');
  });

  it('still loads circles for an explicit open or the circle adder after a false hint', () => {
    const dispatch = jest.fn(action => {
      if (typeof action === 'function') {
        return action(dispatch, state);
      }

      return action;
    });

    featureUsageFlag.mockReturnValue(false);
    fetchCircles()(dispatch, state);
    expect(get).toHaveBeenCalledWith('/api/v1/circles');

    get.mockClear();
    setupCircleAdder('account-1')(dispatch, state);
    expect(get.mock.calls.map(call => call[0])).toEqual([
      '/api/v1/circles',
      '/api/v1/accounts/account-1/circles',
    ]);
  });

  it('still loads lists for an explicit open or the list adder when the viewer owned none at boot', () => {
    const dispatch = jest.fn(action => {
      if (typeof action === 'function') {
        return action(dispatch, state);
      }

      return action;
    });

    featureUsageFlag.mockReturnValue(false);
    fetchLists()(dispatch, state);
    expect(get).toHaveBeenCalledWith('/api/v1/lists');

    get.mockClear();
    setupListAdder('account-1')(dispatch, state);
    expect(get.mock.calls.map(call => call[0])).toEqual([
      '/api/v1/lists',
      '/api/v1/accounts/account-1/lists',
    ]);
    expect(featureUsageFlag).not.toHaveBeenCalled();
  });
});
