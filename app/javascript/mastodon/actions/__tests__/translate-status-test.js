import { fromJS } from 'immutable';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedStatus: jest.fn(),
  importFetchedStatuses: jest.fn(),
  importFetchedAccount: jest.fn(),
}));

jest.mock('../accounts', () => ({
  fetchRelationshipsFromStatus: jest.fn(),
  fetchRelationshipsFromStatuses: jest.fn(),
}));

jest.mock('../timelines', () => ({
  deleteFromTimelines: jest.fn(),
  expireFromTimelines: jest.fn(),
}));

jest.mock('../compose', () => ({
  ensureComposeIsVisible: jest.fn(),
  getContextReference: jest.fn(),
  setComposeToStatus: jest.fn(),
}));

jest.mock('../modal', () => ({
  openModal: jest.fn(),
}));

import api from '../../api';
import {
  translateStatus,
  undoStatusTranslation,
  STATUS_TRANSLATE_REQUEST,
  STATUS_TRANSLATE_SUCCESS,
  STATUS_TRANSLATE_FAIL,
  STATUS_TRANSLATE_UNDO,
  STATUS_TRANSLATE_SET_MODE,
} from '../statuses';

const dispatchThunk = (thunk, state) => {
  const actions = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    actions.push(action);
    return action;
  };

  return Promise.resolve(thunk(dispatch, () => state)).then(() => actions);
};

describe('translateStatus', () => {
  const state = fromJS({
    statuses: {
      s1: { id: 's1', account: 'a1' },
    },
    accounts: {
      a1: { acct: 'alice@remote.example' },
    },
  });

  beforeEach(() => {
    api.mockReset();
  });

  it('posts to the status translate endpoint and stores the response', async () => {
    const translation = { content: '<p>こんにちは</p>', provider: 'DeepL', language: 'ja' };
    const post = jest.fn(() => Promise.resolve({ data: translation }));
    api.mockReturnValue({ post });

    const actions = await dispatchThunk(translateStatus('s1'), state);

    expect(post).toHaveBeenCalledWith('/api/v1/statuses/s1/translate');
    expect(actions.map(action => action.type)).toEqual([
      STATUS_TRANSLATE_REQUEST,
      STATUS_TRANSLATE_SUCCESS,
    ]);
    expect(actions[1]).toMatchObject({
      id: 's1',
      translation,
      domain: 'remote.example',
    });
  });

  it('dispatches a failure action when the request fails', async () => {
    const error = new Error('nope');
    api.mockReturnValue({ post: jest.fn(() => Promise.reject(error)) });

    const actions = await dispatchThunk(translateStatus('s1'), state);

    expect(actions.map(action => action.type)).toEqual([
      STATUS_TRANSLATE_REQUEST,
      STATUS_TRANSLATE_FAIL,
    ]);
    expect(actions[1].error).toBe(error);
  });

  it('stores the requested bilingual mode and does not post again once translated', async () => {
    const translation = { content: '<p>こんにちは</p>', provider: 'LibreTranslate', language: 'ja' };
    const post = jest.fn(() => Promise.resolve({ data: translation }));
    api.mockReturnValue({ post });

    const actions = await dispatchThunk(translateStatus('s1', 'bilingual'), state);

    expect(post).toHaveBeenCalledTimes(1);
    expect(post).toHaveBeenCalledWith('/api/v1/statuses/s1/translate');
    expect(actions[0]).toMatchObject({ type: STATUS_TRANSLATE_REQUEST, id: 's1', mode: 'bilingual' });
    expect(actions[1]).toMatchObject({ type: STATUS_TRANSLATE_SUCCESS, mode: 'bilingual', translation });

    const translated = state.setIn(['statuses', 's1', 'translation'], translation);
    post.mockClear();
    const switched = await dispatchThunk(translateStatus('s1', 'translated'), translated);

    expect(post).not.toHaveBeenCalled();
    expect(switched).toEqual([{
      type: STATUS_TRANSLATE_SET_MODE,
      id: 's1',
      mode: 'translated',
    }]);
  });

  it('does not send a second request while a translation is pending', async () => {
    const post = jest.fn(() => Promise.resolve({ data: {} }));
    api.mockReturnValue({ post });

    const pending = state.setIn(['statuses', 's1', 'translationPending'], true);
    const actions = await dispatchThunk(translateStatus('s1', 'bilingual'), pending);

    expect(post).not.toHaveBeenCalled();
    expect(actions).toEqual([]);
  });
});

describe('undoStatusTranslation', () => {
  it('drops translation state without calling the API', () => {
    api.mockClear();

    expect(undoStatusTranslation('s1', 'p1')).toEqual({
      type: STATUS_TRANSLATE_UNDO,
      id: 's1',
      pollId: 'p1',
    });
    expect(api).not.toHaveBeenCalled();
  });
});
