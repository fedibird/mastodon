import {
  fetchNotificationFilters,
  NOTIFICATION_FILTERS_FETCH_REQUEST,
  NOTIFICATION_FILTERS_FETCH_SUCCESS,
} from '../notification_filters';
import notificationFilters from '../../reducers/notification_filters';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: jest.fn(),
}));

import api from '../../api';

const v1Filters = [{
  id: '1',
  phrase: 'spam',
  context: ['notifications'],
  irreversible: true,
  whole_word: false,
  expires_at: null,
}];

describe('notification_filters reducer', () => {
  it('stores fetched legacy v1 filters as a list', () => {
    const state = notificationFilters(undefined, {
      type: NOTIFICATION_FILTERS_FETCH_SUCCESS,
      filters: v1Filters,
    });

    expect(state.size).toEqual(1);
    expect(state.getIn([0, 'phrase'])).toEqual('spam');
    expect(state.getIn([0, 'irreversible'])).toEqual(true);
  });
});

describe('fetchNotificationFilters', () => {
  it('loads legacy /api/v1/filters into the notification filter cache', async () => {
    const get = jest.fn().mockResolvedValue({ data: v1Filters });
    api.mockReturnValue({ get });

    const dispatch = jest.fn();
    const getState = jest.fn();

    fetchNotificationFilters()(dispatch, getState);
    await Promise.resolve();

    expect(get).toHaveBeenCalledWith('/api/v1/filters');
    expect(dispatch).toHaveBeenCalledWith(expect.objectContaining({
      type: NOTIFICATION_FILTERS_FETCH_REQUEST,
    }));
    expect(dispatch).toHaveBeenCalledWith(expect.objectContaining({
      type: NOTIFICATION_FILTERS_FETCH_SUCCESS,
      filters: v1Filters,
    }));
  });
});
