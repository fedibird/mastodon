jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: jest.fn(() => ({ refs: [] })),
}));

jest.mock('../importer', () => ({
  importFetchedStatuses: jest.fn(() => ({ type: 'IMPORT_STATUSES' })),
  importFetchedAccounts: jest.fn(() => ({ type: 'IMPORT_ACCOUNTS' })),
}));

jest.mock('../accounts', () => ({
  fetchRelationshipsSuccess: jest.fn(() => ({ type: 'REL_SUCCESS' })),
  fetchRelationshipsFromStatuses: jest.fn(() => ({ type: 'REL_FROM_STATUSES' })),
}));

import { fromJS } from 'immutable';
import api from '../../api';
import { fetchBookmarkedStatuses } from '../bookmarks';
import { fetchFavouritedStatuses } from '../favourites';

const get = jest.fn();
const getState = () => fromJS({
  status_lists: {
    bookmarks: { isLoading: false },
    favourites: { isLoading: false },
  },
});

describe('saved timeline API order requests', () => {
  beforeEach(() => {
    get.mockReset();
    get.mockResolvedValue({ data: [{ id: '123' }], headers: {} });
    api.mockImplementation(() => ({ get }));
  });

  it.each([
    ['bookmarks', fetchBookmarkedStatuses],
    ['favourites', fetchFavouritedStatuses],
  ])('keeps %s record order when the toggle is off', async (resource, fetchStatuses) => {
    const dispatch = jest.fn();

    await fetchStatuses({ sortByPostDate: false })(dispatch, getState);

    expect(get).toHaveBeenCalledWith(`/api/v1/${resource}?compact=true`);
  });

  it.each([
    ['bookmarks', fetchBookmarkedStatuses],
    ['favourites', fetchFavouritedStatuses],
  ])('adds order=status and filters only when %s requests them', async (resource, fetchStatuses) => {
    const dispatch = jest.fn();

    await fetchStatuses({ sortByPostDate: true, onlyMedia: true })(dispatch, getState);

    expect(get).toHaveBeenCalledWith(`/api/v1/${resource}?compact=true&only_media=true&order=status`);
  });
});
