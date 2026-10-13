const mockConnectUserStream = jest.fn();
const mockConnectUserPreferences = jest.fn();

jest.mock('../../actions/streaming', () => ({
  connectUserStream: () => mockConnectUserStream(),
}));

jest.mock('../../actions/user_preferences', () => ({
  connectUserPreferences: () => mockConnectUserPreferences(),
}));

import { Map as ImmutableMap } from 'immutable';
import { startMastodonSubscriptions } from '../mastodon_subscriptions';

const storeFor = () => {
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => ImmutableMap());
    }

    return action;
  };

  return { dispatch };
};

describe('mastodon root subscriptions', () => {
  beforeEach(() => {
    mockConnectUserStream.mockReset();
    mockConnectUserPreferences.mockReset();
  });

  it('keeps the user stream up and stops both subscriptions on unmount', () => {
    const userStops = [];
    const preferenceStops = [];

    mockConnectUserStream.mockImplementation(() => () => () => {
      userStops.push('stop');
    });
    mockConnectUserPreferences.mockImplementation(() => () => () => {
      preferenceStops.push('stop');
    });

    const disconnect = startMastodonSubscriptions(storeFor());

    expect(mockConnectUserStream).toHaveBeenCalledTimes(1);
    expect(mockConnectUserPreferences).toHaveBeenCalledTimes(1);
    expect(userStops).toEqual([]);
    expect(preferenceStops).toEqual([]);

    disconnect();

    expect(userStops).toEqual(['stop']);
    expect(preferenceStops).toEqual(['stop']);

    disconnect();

    expect(userStops).toEqual(['stop']);
    expect(preferenceStops).toEqual(['stop']);
  });
});
