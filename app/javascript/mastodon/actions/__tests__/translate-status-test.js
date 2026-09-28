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

jest.mock('../../initial_state', () => ({
  locale: 'ja',
}));

import api from '../../api';
import statusesReducer from '../../reducers/statuses';
import {
  translateStatus,
  setStatusTranslationAssumption,
  undoStatusTranslation,
  STATUS_TRANSLATE_REQUEST,
  STATUS_TRANSLATE_SUCCESS,
  STATUS_TRANSLATE_FAIL,
  STATUS_TRANSLATE_UNDO,
  STATUS_TRANSLATE_SET_MODE,
} from '../statuses';

const createDispatch = (initialState) => {
  let state = initialState;
  const actions = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    actions.push(action);

    if (action.type === STATUS_TRANSLATE_REQUEST) {
      state = state.setIn(['statuses', action.id, 'translationPending'], true)
        .setIn(['statuses', action.id, 'translationRequestId'], action.translationRequestId);
    }

    return action;
  };

  return {
    actions,
    dispatch,
    getState: () => state,
    setState: (next) => {
      state = next;
    },
    run: (thunk) => Promise.resolve(thunk(dispatch, () => state)),
  };
};

const dropTranslationRequest = (state, id) => state
  .deleteIn(['statuses', id, 'translationPending'])
  .deleteIn(['statuses', id, 'translationRequestId']);

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

    const store = createDispatch(state);
    await store.run(translateStatus('s1'));
    const { actions } = store;

    expect(post).toHaveBeenCalledWith('/api/v1/statuses/s1/translate', {
      source_language: 'und',
      target_language: 'ja',
    });
    expect(actions.map(action => action.type)).toEqual([
      STATUS_TRANSLATE_REQUEST,
      STATUS_TRANSLATE_SUCCESS,
    ]);
    expect(actions[0].translationRequestId).toEqual(expect.any(String));
    expect(actions[1]).toMatchObject({
      id: 's1',
      translation,
      domain: 'remote.example',
      translationRequestId: actions[0].translationRequestId,
    });
  });

  it('dispatches a failure action when the request fails', async () => {
    const error = new Error('nope');
    api.mockReturnValue({ post: jest.fn(() => Promise.reject(error)) });

    const store = createDispatch(state);
    await store.run(translateStatus('s1'));
    const { actions } = store;

    expect(actions.map(action => action.type)).toEqual([
      STATUS_TRANSLATE_REQUEST,
      STATUS_TRANSLATE_FAIL,
    ]);
    expect(actions[1].error).toBe(error);
    expect(actions[1].skipAlert).toBeUndefined();
    expect(actions[1].translationRequestId).toBe(actions[0].translationRequestId);
  });

  it('stores the requested bilingual mode and does not post again once translated', async () => {
    const translation = { content: '<p>こんにちは</p>', provider: 'LibreTranslate', language: 'ja' };
    const post = jest.fn(() => Promise.resolve({ data: translation }));
    api.mockReturnValue({ post });

    const store = createDispatch(state);
    await store.run(translateStatus('s1', 'bilingual'));
    const { actions } = store;

    expect(post).toHaveBeenCalledTimes(1);
    expect(post).toHaveBeenCalledWith('/api/v1/statuses/s1/translate', {
      source_language: 'und',
      target_language: 'ja',
    });
    expect(actions[0]).toMatchObject({ type: STATUS_TRANSLATE_REQUEST, id: 's1', mode: 'bilingual' });
    expect(actions[1]).toMatchObject({
      type: STATUS_TRANSLATE_SUCCESS,
      mode: 'bilingual',
      translation,
      translationRequestId: actions[0].translationRequestId,
    });

    const translated = state.setIn(['statuses', 's1', 'translation'], translation);
    post.mockClear();
    const switchedStore = createDispatch(translated);
    await switchedStore.run(translateStatus('s1', 'translated'));
    const switched = switchedStore.actions;

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
    const store = createDispatch(pending);
    await store.run(translateStatus('s1', 'bilingual'));
    const { actions } = store;

    expect(post).not.toHaveBeenCalled();
    expect(actions).toEqual([]);
  });

  it('does not alert when an older request fails after the source changes', async () => {
    const deferreds = [];
    const post = jest.fn(() => new Promise((resolve, reject) => {
      deferreds.push({ resolve, reject });
    }));
    api.mockReturnValue({ post });

    const store = createDispatch(state.setIn(['statuses', 's1', 'poll'], 'p1'));
    const first = store.run(translateStatus('s1'));
    const requestA = store.actions[0].translationRequestId;

    store.setState(dropTranslationRequest(store.getState(), 's1'));
    deferreds[0].reject(new Error('timeout'));
    await first;

    expect(store.actions.map(action => action.type)).toEqual([
      STATUS_TRANSLATE_REQUEST,
      STATUS_TRANSLATE_FAIL,
    ]);
    expect(store.actions[1]).toMatchObject({
      translationRequestId: requestA,
      pollId: 'p1',
      skipAlert: true,
    });
    expect(store.actions.some(action => action.type === STATUS_TRANSLATE_SUCCESS)).toBe(false);
  });

  it('does not dispatch success when an older request finishes after the source changes', async () => {
    const deferreds = [];
    const post = jest.fn(() => new Promise((resolve) => {
      deferreds.push({ resolve });
    }));
    api.mockReturnValue({ post });

    const store = createDispatch(state.setIn(['statuses', 's1', 'poll'], 'p1'));
    const first = store.run(translateStatus('s1'));

    store.setState(dropTranslationRequest(store.getState(), 's1'));
    deferreds[0].resolve({ data: { content: '<p>古い</p>', poll: { id: 'p1', options: [] } } });
    await first;

    expect(store.actions.map(action => action.type)).toEqual([
      STATUS_TRANSLATE_REQUEST,
    ]);
  });

  it('keeps the newer request when an older request completes', async () => {
    const deferreds = [];
    const post = jest.fn(() => new Promise((resolve) => {
      deferreds.push({ resolve });
    }));
    api.mockReturnValue({ post });

    const store = createDispatch(state.setIn(['statuses', 's1', 'poll'], 'p1'));
    const first = store.run(translateStatus('s1'));
    const requestA = store.actions[0].translationRequestId;

    store.setState(dropTranslationRequest(store.getState(), 's1'));
    const second = store.run(translateStatus('s1', 'bilingual'));
    const requestB = store.actions[1].translationRequestId;

    expect(requestB).not.toBe(requestA);
    expect(store.getState().getIn(['statuses', 's1', 'translationPending'])).toBe(true);
    expect(store.getState().getIn(['statuses', 's1', 'translationRequestId'])).toBe(requestB);

    deferreds[0].resolve({ data: { content: '<p>古い</p>' } });
    await first;

    expect(store.actions.filter(action => action.type === STATUS_TRANSLATE_SUCCESS)).toEqual([]);
    expect(store.getState().getIn(['statuses', 's1', 'translationPending'])).toBe(true);
    expect(store.getState().getIn(['statuses', 's1', 'translationRequestId'])).toBe(requestB);

    deferreds[1].resolve({ data: { content: '<p>新しい</p>' } });
    await second;

    expect(store.actions.filter(action => action.type === STATUS_TRANSLATE_SUCCESS)).toEqual([
      expect.objectContaining({
        translationRequestId: requestB,
        mode: 'bilingual',
        translation: expect.objectContaining({
          content: '<p>新しい</p>',
          requested_source_language: 'und',
          requested_target_language: 'ja',
        }),
      }),
    ]);
  });

  it('treats only the newer failure as an alert', async () => {
    const deferreds = [];
    const post = jest.fn(() => new Promise((resolve, reject) => {
      deferreds.push({ resolve, reject });
    }));
    api.mockReturnValue({ post });

    const store = createDispatch(state.setIn(['statuses', 's1', 'poll'], 'p1'));
    const first = store.run(translateStatus('s1'));
    const requestA = store.actions[0].translationRequestId;

    store.setState(dropTranslationRequest(store.getState(), 's1'));
    const second = store.run(translateStatus('s1'));
    const requestB = store.actions[1].translationRequestId;

    deferreds[0].reject(new Error('timeout'));
    await first;

    expect(store.actions.filter(action => action.type === STATUS_TRANSLATE_FAIL)).toEqual([
      expect.objectContaining({
        translationRequestId: requestA,
        skipAlert: true,
      }),
    ]);
    expect(store.getState().getIn(['statuses', 's1', 'translationPending'])).toBe(true);
    expect(store.getState().getIn(['statuses', 's1', 'translationRequestId'])).toBe(requestB);

    deferreds[1].reject(new Error('unavailable'));
    await second;

    expect(store.actions.filter(action => action.type === STATUS_TRANSLATE_FAIL && !action.skipAlert)).toEqual([
      expect.objectContaining({
        translationRequestId: requestB,
        error: expect.any(Error),
      }),
    ]);
  });

  it('requests again when the viewer pair differs from the stored request pair', async () => {
    const post = jest.fn(() => Promise.resolve({ data: { content: '<p>再翻訳</p>', language: 'ja' } }));
    api.mockReturnValue({ post });

    const translated = state.setIn(['statuses', 's1', 'language'], 'en').setIn(['statuses', 's1', 'translation'], fromJS({
      content: '<p>こんにちは</p>',
      language: 'ja',
      requested_source_language: 'en',
      requested_target_language: 'ja',
    }));
    const samePair = createDispatch(translated);
    await samePair.run(translateStatus('s1', 'bilingual'));

    expect(post).not.toHaveBeenCalled();
    expect(samePair.actions).toEqual([{
      type: STATUS_TRANSLATE_SET_MODE,
      id: 's1',
      mode: 'bilingual',
    }]);

    const differentPair = createDispatch(translated.setIn(['translation_assumptions', 's1'], fromJS({
      source: 'fr',
      target: 'ja',
    })));
    await differentPair.run(translateStatus('s1', 'translated'));

    expect(post).toHaveBeenCalledWith('/api/v1/statuses/s1/translate', {
      source_language: 'fr',
      target_language: 'ja',
    });
    expect(differentPair.actions[1].translation).toMatchObject({
      content: '<p>再翻訳</p>',
      requested_source_language: 'fr',
      requested_target_language: 'ja',
    });
  });

  it('drops an in-flight request when the viewer pair changes so only the new pair is stored', async () => {
    const deferreds = [];
    const post = jest.fn(() => new Promise((resolve, reject) => {
      deferreds.push({ resolve, reject });
    }));
    api.mockReturnValue({ post });

    const initial = state.setIn(['statuses', 's1', 'language'], 'en').setIn(['statuses', 's1', 'poll'], 'p1');
    const store = createDispatch(initial);
    const first = store.run(translateStatus('s1'));
    const requestA = store.actions[0].translationRequestId;

    const cleared = statusesReducer(store.getState().get('statuses'), setStatusTranslationAssumption('s1', 'fr', 'ja'));
    expect(cleared.getIn(['s1', 'translationPending'])).toBe(false);
    expect(cleared.getIn(['s1', 'translationRequestId'])).toBeUndefined();
    expect(cleared.getIn(['s1', 'language'])).toBe('en');

    store.setState(store.getState()
      .set('statuses', cleared)
      .setIn(['translation_assumptions', 's1'], fromJS({ source: 'fr', target: 'ja' })));

    const second = store.run(translateStatus('s1'));
    const requestB = store.actions[1].translationRequestId;

    expect(requestB).not.toBe(requestA);
    expect(post).toHaveBeenLastCalledWith('/api/v1/statuses/s1/translate', {
      source_language: 'fr',
      target_language: 'ja',
    });

    deferreds[0].resolve({ data: { content: '<p>古い</p>', poll: { id: 'p1', options: [{ title: '古い' }] }, media_attachments: [{ id: 'm1', description: '古い' }] } });
    await first;

    expect(store.actions.filter(action => action.type === STATUS_TRANSLATE_SUCCESS)).toEqual([]);
    expect(store.actions.filter(action => action.type === STATUS_TRANSLATE_FAIL)).toEqual([]);

    deferreds[1].reject(new Error('nope'));
    await second;

    expect(store.actions.filter(action => action.type === STATUS_TRANSLATE_FAIL && action.skipAlert)).toEqual([]);
    expect(store.actions.filter(action => action.type === STATUS_TRANSLATE_FAIL && !action.skipAlert)).toEqual([
      expect.objectContaining({ translationRequestId: requestB }),
    ]);
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
