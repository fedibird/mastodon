jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import axios from 'axios';
import { fromJS, Map as ImmutableMap } from 'immutable';

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

import api, { getLinks } from '../../api';
import reducer from '../../reducers/emoji_reactioned_statuses';
import {
  expandEmojiReactionedStatuses,
  fetchEmojiReactionEmojiCatalog,
  fetchEmojiReactionedStatuses,
  getEmojiReactionQueryKey,
  pinnedEmojiReactionColumnParams,
} from '../emoji_reactions';

const get = jest.fn();

const createHarness = (initial = reducer(undefined, { type: '@@INIT' })) => {
  let slice = initial;
  const dispatch = action => {
    if (typeof action === 'function') {
      return action(dispatch, () => ImmutableMap({ emoji_reactioned_statuses: slice }));
    }

    slice = reducer(slice, action);
    return action;
  };

  return {
    dispatch,
    read: () => slice,
  };
};

describe('emoji reaction API actions', () => {
  beforeEach(() => {
    get.mockReset();
    get.mockResolvedValue({ data: [{ id: '1' }], headers: {} });
    api.mockImplementation(() => ({ get }));
    getLinks.mockImplementation(() => ({ refs: [] }));
  });

  it('sends compact and emojis[] without the list key', async () => {
    const { dispatch } = createHarness();

    await dispatch(fetchEmojiReactionedStatuses({
      listKey: 'column-a',
      emojis: ['🎉', 'great@example.com'],
      onlyMedia: false,
      withoutMedia: false,
    }));

    expect(get).toHaveBeenCalledWith('/api/v1/emoji_reactions', {
      params: {
        compact: true,
        emojis: ['🎉', 'great@example.com'],
      },
    });

    const uri = axios.create().getUri({
      url: '/api/v1/emoji_reactions',
      params: get.mock.calls[0][1].params,
    });
    const query = new URLSearchParams(uri.split('?')[1]);

    expect(query.get('compact')).toBe('true');
    expect(query.getAll('emojis[]')).toEqual(['🎉', 'great@example.com']);
    expect(query.has('listKey')).toBe(false);
    expect(uri).not.toContain('listKey');
  });

  it('keeps settings order in the request and treats reversed filters as the same query', async () => {
    const { dispatch, read } = createHarness();

    await dispatch(fetchEmojiReactionedStatuses({
      listKey: 'default',
      emojis: ['🎉', '👍'],
    }));

    expect(get.mock.calls[0][1].params.emojis).toEqual(['🎉', '👍']);
    expect(read().getIn(['lists', 'default', 'filters', 'emojis']).toJS()).toEqual(['🎉', '👍']);
    expect(getEmojiReactionQueryKey({ emojis: ['🎉', '👍'] })).toBe(getEmojiReactionQueryKey({ emojis: ['👍', '🎉', '👍'] }));
    expect(pinnedEmojiReactionColumnParams({
      emojis: fromJS(['achievement@example.com', '🎉']),
      onlyMedia: false,
      withoutMedia: true,
    })).toEqual({
      emojis: ['achievement@example.com', '🎉'],
      other: { onlyMedia: false, withoutMedia: true },
    });
  });

  it('starts a new request when the filter changes during loading and skips the same in-flight query', () => {
    get.mockImplementation(() => new Promise(() => {}));
    const { dispatch } = createHarness();

    dispatch(fetchEmojiReactionedStatuses({ listKey: 'column-a', emojis: ['🎉'] }));
    dispatch(fetchEmojiReactionedStatuses({ listKey: 'column-a', emojis: ['🎉'] }));
    dispatch(fetchEmojiReactionedStatuses({ listKey: 'column-a', emojis: ['👍'] }));
    dispatch(fetchEmojiReactionedStatuses({ listKey: 'column-b', emojis: ['🎉'] }));

    expect(get).toHaveBeenCalledTimes(3);
    expect(get.mock.calls[1][1].params.emojis).toEqual(['👍']);
    expect(get.mock.calls[2][1].params.emojis).toEqual(['🎉']);
  });

  it('loads the next page from the stored URL', async () => {
    const nextUrl = '/api/v1/emoji_reactions?compact=true&emojis[]=%F0%9F%8E%89&max_id=1';
    getLinks.mockImplementation(() => ({ refs: [{ rel: 'next', uri: nextUrl }] }));
    const { dispatch } = createHarness();

    await dispatch(fetchEmojiReactionedStatuses({ listKey: 'column-a', emojis: ['🎉'] }));
    get.mockClear();
    getLinks.mockImplementation(() => ({ refs: [] }));

    await dispatch(expandEmojiReactionedStatuses('column-a'));

    expect(get).toHaveBeenCalledTimes(1);
    expect(get).toHaveBeenCalledWith(nextUrl);
  });

  it('fetches the emoji catalog once while a request is already loading', async () => {
    let resolveCatalog;
    get.mockImplementation(() => new Promise(resolve => {
      resolveCatalog = resolve;
    }));
    const harness = createHarness();

    const first = harness.dispatch(fetchEmojiReactionEmojiCatalog());
    harness.dispatch(fetchEmojiReactionEmojiCatalog());

    expect(get).toHaveBeenCalledTimes(1);
    expect(get).toHaveBeenCalledWith('/api/v1/emoji_reactions/emojis');

    resolveCatalog({
      data: [
        { name: '🎉', count: 2 },
        { name: '👍', count: 1 },
      ],
    });
    await first;

    expect(harness.read().getIn(['catalog', 'items']).map(item => item.get('name')).toJS()).toEqual(['🎉', '👍']);
    expect(harness.read().getIn(['catalog', 'loaded'])).toBe(true);

    get.mockClear();
    harness.dispatch(fetchEmojiReactionEmojiCatalog());
    expect(get).not.toHaveBeenCalled();
  });
});
