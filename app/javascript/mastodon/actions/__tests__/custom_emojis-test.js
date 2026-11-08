import { Map as ImmutableMap, List as ImmutableList } from 'immutable';
import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';
import api from 'mastodon/api';
import custom_emojis from '../../reducers/custom_emojis';
import customEmojiCatalog from '../../reducers/custom_emoji_catalog';
import {
  ensureCustomEmojis,
  resetCustomEmojiCatalogForTests,
} from '../custom_emojis';

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

const combine = (state = ImmutableMap(), action) => ImmutableMap({
  custom_emojis: custom_emojis(state.get('custom_emojis'), action),
  custom_emoji_catalog: customEmojiCatalog(state.get('custom_emoji_catalog'), action),
});

const makeStore = () => createStore(combine, applyMiddleware(thunk));

describe('ensureCustomEmojis', () => {
  beforeEach(() => {
    resetCustomEmojiCatalogForTests();
    api.mockReset();
  });

  it('shares one request, keeps an empty success, and lets a failure be retried', async () => {
    let rejectFirst;
    const first = new Promise((_resolve, reject) => {
      rejectFirst = reject;
    });
    const success = jest.fn(() => Promise.resolve({ data: [] }));
    api.mockReturnValue({ get: jest.fn(() => first) });

    const left = makeStore();
    const right = makeStore();
    const leftRequest = left.dispatch(ensureCustomEmojis());
    const rightRequest = right.dispatch(ensureCustomEmojis());

    expect(api).toHaveBeenCalledTimes(1);
    rejectFirst(new Error('offline'));
    await expect(leftRequest).rejects.toThrow('offline');
    await expect(rightRequest).rejects.toThrow('offline');
    expect(left.getState().getIn(['custom_emoji_catalog', 'status'])).toBe('error');
    expect(ImmutableList.isList(left.getState().get('custom_emojis'))).toBe(true);

    api.mockReturnValue({ get: success });
    await left.dispatch(ensureCustomEmojis());
    await right.dispatch(ensureCustomEmojis());
    await left.dispatch(ensureCustomEmojis());

    expect(success).toHaveBeenCalledTimes(1);
    expect(left.getState().getIn(['custom_emoji_catalog', 'status'])).toBe('ready');
    expect(right.getState().getIn(['custom_emoji_catalog', 'status'])).toBe('ready');
    expect(left.getState().get('custom_emojis').size).toBe(0);
    expect(right.getState().get('custom_emojis').size).toBe(0);
  });
});
