import { fromJS } from 'immutable';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedStatuses: jest.fn(statuses => ({ type: 'STATUSES_IMPORT', statuses })),
}));

import api, { getLinks } from '../../api';
import {
  fetchTrendingHashtags,
  fetchTrendingLinks,
  fetchTrendingStatuses,
  expandTrendingStatuses,
  TRENDS_TAGS_FETCH_SUCCESS,
  TRENDS_LINKS_FETCH_SUCCESS,
  TRENDS_STATUSES_FETCH_SUCCESS,
  TRENDS_STATUSES_EXPAND_SUCCESS,
} from '../trends';

const dispatchThunk = async (thunk, state) => {
  const actions = [];
  const dispatch = action => {
    actions.push(action);
    return action;
  };

  await thunk(dispatch, () => state);
  return actions;
};

describe('trends actions', () => {
  beforeEach(() => {
    api.mockReset();
    getLinks.mockReset();
    getLinks.mockReturnValue({ refs: [] });
  });

  it.each([
    ['tags', fetchTrendingHashtags, TRENDS_TAGS_FETCH_SUCCESS],
    ['links', fetchTrendingLinks, TRENDS_LINKS_FETCH_SUCCESS],
  ])('fetches trending %s from the split endpoint', async (resource, action, successType) => {
    const get = jest.fn().mockResolvedValue({ data: [{ id: resource }] });
    api.mockReturnValue({ get });

    const actions = await dispatchThunk(action(), fromJS({}));

    expect(get).toHaveBeenCalledWith(`/api/v1/trends/${resource}`);
    expect(actions).toContainEqual(expect.objectContaining({ type: successType }));
  });

  it('fetches and imports the first trending statuses page with pagination', async () => {
    const response = { data: [{ id: '1' }] };
    const get = jest.fn().mockResolvedValue(response);
    api.mockReturnValue({ get });
    getLinks.mockReturnValue({ refs: [{ rel: 'next', uri: '/api/v1/trends/statuses?max_id=1' }] });

    const actions = await dispatchThunk(fetchTrendingStatuses(), fromJS({
      status_lists: { trending: { isLoading: false } },
    }));

    expect(get).toHaveBeenCalledWith('/api/v1/trends/statuses');
    expect(actions).toContainEqual(expect.objectContaining({
      type: TRENDS_STATUSES_FETCH_SUCCESS,
      next: '/api/v1/trends/statuses?max_id=1',
    }));
    expect(actions).toContainEqual({ type: 'STATUSES_IMPORT', statuses: response.data });
  });

  it('uses the stored next URL when expanding trending statuses', async () => {
    const nextUrl = '/api/v1/trends/statuses?max_id=1';
    const get = jest.fn().mockResolvedValue({ data: [{ id: '2' }] });
    api.mockReturnValue({ get });
    getLinks.mockReturnValue({ refs: [] });

    const actions = await dispatchThunk(expandTrendingStatuses(), fromJS({
      status_lists: { trending: { isLoading: false, next: nextUrl } },
    }));

    expect(get).toHaveBeenCalledWith(nextUrl);
    expect(actions).toContainEqual(expect.objectContaining({
      type: TRENDS_STATUSES_EXPAND_SUCCESS,
      next: null,
    }));
  });
});
