import { Map as ImmutableMap, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedAccounts: jest.fn(accounts => ({ type: 'ACCOUNTS_IMPORT', accounts })),
  importFetchedStatus: jest.fn(status => ({ type: 'STATUS_IMPORT', status })),
}));

jest.mock('../../selectors', () => ({
  getHomeVisibilities: () => ['public'],
  getLimitedVisibilities: () => ['private'],
}));

import api from '../../api';
import {
  COMPOSE_REFERENCE_ADD,
  COMPOSE_REPLY,
  COMPOSE_SUBMIT_FAIL,
  COMPOSE_SUBMIT_REQUEST,
  COMPOSE_SUBMIT_SUCCESS,
  COMPOSE_SUGGESTIONS_READY,
  COMPOSE_UPLOAD_PROGRESS,
  COMPOSE_UPLOAD_REQUEST,
  COMPOSE_UPLOAD_SUCCESS,
  COMPOSE_VISIBILITY_CHANGE,
  INIT_MEDIA_EDIT_MODAL,
  addReferenceToComposer,
  changeCompose,
  changeComposeVisibility,
  changeComposerUpload,
  directInComposer,
  fetchComposerSuggestions,
  initComposerMediaEditModal,
  mentionInComposer,
  quoteInComposer,
  replyCompose,
  replyInComposer,
  submitComposeRequest,
  submitComposer,
  uploadToComposer,
} from '../compose';
import { createComposer, destroyComposer, targetComposerAction } from '../composer';
import { MODAL_OPEN } from '../modal';
import compose from '../../reducers/compose';
import composers from '../../reducers/composers';

const statusResponse = {
  id: 's1',
  visibility: 'public',
  in_reply_to_id: null,
  scheduled_at: null,
  tags: [],
  account: { id: 'a1' },
};

const reducer = combineReducers({
  compose,
  composers,
  timelines: (state = ImmutableMap()) => state,
  meta: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
  accounts: (state = ImmutableMap()) => state,
});

const makeStore = (preloadedState) => {
  const actions = [];
  const recorder = () => next => action => {
    if (action && action.type) {
      actions.push(action);
    }

    return next(action);
  };

  const store = createStore(
    reducer,
    preloadedState,
    applyMiddleware(recorder, thunk),
  );

  return { store, actions };
};

const router = {
  location: { pathname: '/home' },
  push: jest.fn(),
  goBack: jest.fn(),
};

const replyStatus = fromJS({
  id: 'status-1',
  visibility: 'public',
  language: 'en',
  spoiler_text: '',
  status_reference_ids: [],
  in_reply_to_id: null,
  mentions: [],
  account: { id: 'acc-1', acct: 'alice' },
});

const preparePortableDraft = (store) => {
  store.dispatch(createComposer('composer-a'));
  store.dispatch(targetComposerAction(changeCompose('PRIMARY'), 'primary'));
  store.dispatch(changeCompose('PRIMARY'));
  store.dispatch(targetComposerAction(changeCompose('PORTABLE'), 'composer-a'));
  store.dispatch(targetComposerAction(changeComposeVisibility('private'), 'composer-a'));

  return store.getState().getIn(['composers', 'byId', 'composer-a', 'idempotencyKey']);
};

describe('composer async routing', () => {
  beforeEach(() => {
    api.mockReset();
    router.push.mockClear();
    router.goBack.mockClear();
  });

  it('builds a portable submit from that composer snapshot and routes the lifecycle home', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const { store, actions } = makeStore();
    const idempotencyKey = preparePortableDraft(store);

    await store.dispatch(submitComposer('composer-a', router));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
      headers: { 'Idempotency-Key': idempotencyKey },
    }));
    expect(request.mock.calls[0][0].data.status).toEqual('PORTABLE');
    expect(request.mock.calls[0][0].data.visibility).toEqual('private');
    expect(request.mock.calls[0][0].data.status).not.toEqual('PRIMARY');

    expect(actions.filter(action => action.type === COMPOSE_SUBMIT_REQUEST).map(action => action.meta)).toEqual([
      { composerId: 'composer-a' },
    ]);
    expect(actions.filter(action => action.type === COMPOSE_SUBMIT_SUCCESS).map(action => action.meta)).toEqual([
      { composerId: 'composer-a' },
    ]);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('PRIMARY');
  });

  it('keeps the submit payload on the values captured before later composer edits', async () => {
    const { store } = makeStore();
    const idempotencyKey = preparePortableDraft(store);
    let liveText;
    let livePrivacy;
    let liveKey;
    const request = jest.fn(() => {
      const composer = store.getState().getIn(['composers', 'byId', 'composer-a']);
      liveText = composer.get('text');
      livePrivacy = composer.get('privacy');
      liveKey = composer.get('idempotencyKey');
      return Promise.resolve({ data: statusResponse });
    });

    api.mockImplementation(() => {
      store.dispatch(targetComposerAction(changeCompose('MUTATED'), 'composer-a'));
      store.dispatch(targetComposerAction(changeComposeVisibility('public'), 'composer-a'));
      return { request };
    });

    await store.dispatch(submitComposer('composer-a', router));

    expect(liveText).toEqual('MUTATED');
    expect(livePrivacy).toEqual('public');
    expect(liveKey).not.toEqual(idempotencyKey);
    expect(request.mock.calls[0][0].data.status).toEqual('PORTABLE');
    expect(request.mock.calls[0][0].data.visibility).toEqual('private');
    expect(request.mock.calls[0][0].headers['Idempotency-Key']).toEqual(idempotencyKey);
  });

  it('routes submit failure to the originating composer', async () => {
    const error = new Error('nope');
    api.mockReturnValue({
      request: jest.fn().mockRejectedValue(error),
    });
    const { store, actions } = makeStore();
    preparePortableDraft(store);
    store.dispatch(createComposer('composer-b'));
    store.dispatch(targetComposerAction(submitComposeRequest(), 'composer-b'));

    await store.dispatch(submitComposer('composer-a', router));

    const failure = actions.find(action => action.type === COMPOSE_SUBMIT_FAIL);
    expect(failure.meta).toEqual({ composerId: 'composer-a' });
    expect(failure.error).toBe(error);
    expect(store.getState().getIn(['composers', 'byId', 'composer-b', 'is_submitting'])).toBe(true);
    expect(store.getState().getIn(['compose', 'is_submitting'])).toBe(false);
  });

  it('does not resurrect a composer when submit completes after destroy', async () => {
    let resolveRequest;
    api.mockReturnValue({
      request: jest.fn(() => new Promise(resolve => {
        resolveRequest = resolve;
      })),
    });
    const { store, actions } = makeStore();
    preparePortableDraft(store);

    const pending = store.dispatch(submitComposer('composer-a', router));
    expect(actions.some(action => action.type === COMPOSE_SUBMIT_REQUEST && action.meta.composerId === 'composer-a')).toBe(true);

    store.dispatch(destroyComposer('composer-a'));
    expect(store.getState().getIn(['composers', 'byId', 'composer-a'])).toBeUndefined();

    resolveRequest({ data: statusResponse });
    await pending;

    expect(actions.some(action => action.type === COMPOSE_SUBMIT_SUCCESS && action.meta.composerId === 'composer-a')).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', 'composer-a'])).toBeUndefined();
  });

  it('routes upload progress and success to the originating composer', async () => {
    const file = new File(['hello'], 'a.png', { type: 'image/png' });
    let onUploadProgress;
    const post = jest.fn((url, data, config) => {
      onUploadProgress = config.onUploadProgress;
      return Promise.resolve({ status: 200, data: { id: 'media-1', type: 'image' } });
    });
    api.mockReturnValue({ post });
    const { store, actions } = makeStore();
    store.dispatch(createComposer('composer-a'));
    store.dispatch(changeCompose('PRIMARY'));

    store.dispatch(uploadToComposer('composer-a', [file]));
    onUploadProgress({ loaded: file.size });
    await post.mock.results[0].value;
    await Promise.resolve();

    expect(actions.find(action => action.type === COMPOSE_UPLOAD_REQUEST).meta).toEqual({ composerId: 'composer-a' });
    expect(actions.find(action => action.type === COMPOSE_UPLOAD_PROGRESS).meta).toEqual({ composerId: 'composer-a' });
    expect(actions.find(action => action.type === COMPOSE_UPLOAD_SUCCESS).meta).toEqual({ composerId: 'composer-a' });
    expect(store.getState().getIn(['compose', 'media_attachments']).size).toBe(0);
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'media_attachments']).size).toBe(1);
  });

  it('does not resurrect a composer when an upload completes after destroy', async () => {
    const file = new File(['hello'], 'a.png', { type: 'image/png' });
    let resolvePost;
    api.mockReturnValue({
      post: jest.fn(() => new Promise(resolve => {
        resolvePost = resolve;
      })),
    });
    const { store } = makeStore();
    store.dispatch(createComposer('composer-a'));

    store.dispatch(uploadToComposer('composer-a', [file]));
    store.dispatch(destroyComposer('composer-a'));
    resolvePost({ status: 200, data: { id: 'media-1', type: 'image' } });
    await Promise.resolve();
    await Promise.resolve();

    expect(store.getState().getIn(['composers', 'byId', 'composer-a'])).toBeUndefined();
  });

  it('updates attached media on the composer that owns it', async () => {
    const put = jest.fn();
    api.mockReturnValue({ put });
    const { store, actions } = makeStore();
    store.dispatch(createComposer('composer-a'));
    store.dispatch(targetComposerAction({
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'm1', description: 'old', unattached: false },
      file: null,
      skipLoading: true,
    }, 'composer-a'));

    await store.dispatch(changeComposerUpload('composer-a', 'm1', { description: 'ALT-RED-2', focus: '0.10,-0.20' }));

    expect(put).not.toHaveBeenCalled();
    const success = actions.find(action => action.type === 'COMPOSE_UPLOAD_UPDATE_SUCCESS');
    expect(success.meta).toEqual({ composerId: 'composer-a' });
    expect(success.media.description).toEqual('ALT-RED-2');
    expect(success.media.meta.focus).toEqual({ x: 0.1, y: -0.2 });
    expect(success.attached).toBe(true);
    expect(store.getState().getIn(['compose', 'media_attachments']).size).toBe(0);
  });

  it('starts account suggestion requests for each composer and returns them to that composer', async () => {
    const pending = [];
    const get = jest.fn((url, config) => new Promise(resolve => {
      pending.push({ params: config.params, resolve });
    }));
    api.mockReturnValue({ get });
    const { store, actions } = makeStore();
    store.dispatch(createComposer('composer-a'));
    store.dispatch(createComposer('composer-b'));

    store.dispatch(fetchComposerSuggestions('composer-a', '@alice'));
    store.dispatch(fetchComposerSuggestions('composer-b', '@bob'));

    expect(get).toHaveBeenCalledTimes(2);
    expect(pending.map(request => request.params.q)).toEqual(['alice', 'bob']);

    pending[0].resolve({ data: [{ id: '1', acct: 'alice' }] });
    pending[1].resolve({ data: [{ id: '2', acct: 'bob' }] });
    await Promise.resolve();
    await Promise.resolve();

    const ready = actions.filter(action => action.type === COMPOSE_SUGGESTIONS_READY);
    expect(ready.map(action => [action.token, action.meta.composerId])).toEqual([
      ['@alice', 'composer-a'],
      ['@bob', 'composer-b'],
    ]);
  });

  it('cancels only the originating composer when a newer account search starts', async () => {
    const requests = [];
    const get = jest.fn((url, config) => {
      let cancelled = false;
      config.cancelToken.promise.then(() => {
        cancelled = true;
      }).catch(() => {
        cancelled = true;
      });
      requests.push({
        q: config.params.q,
        wasCancelled: () => cancelled,
      });
      return new Promise(() => {});
    });
    api.mockReturnValue({ get });
    const { store } = makeStore();
    store.dispatch(createComposer('composer-cancel-a'));
    store.dispatch(createComposer('composer-cancel-b'));

    store.dispatch(fetchComposerSuggestions('composer-cancel-a', '@alice'));
    store.dispatch(fetchComposerSuggestions('composer-cancel-b', '@bob'));
    await new Promise(resolve => setTimeout(resolve, 250));
    store.dispatch(fetchComposerSuggestions('composer-cancel-a', '@carol'));
    await Promise.resolve();

    expect(get).toHaveBeenCalledTimes(3);
    expect(requests.map(request => request.q)).toEqual(['alice', 'bob', 'carol']);
    expect(requests[0].wasCancelled()).toBe(true);
    expect(requests[1].wasCancelled()).toBe(false);
  });

  it('opens the focal point modal against the requested composer', () => {
    const { store, actions } = makeStore();
    store.dispatch(createComposer('composer-a'));
    store.dispatch(targetComposerAction({
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'm1', description: 'alt', type: 'image' },
      file: null,
      skipLoading: true,
    }, 'composer-a'));

    store.dispatch(initComposerMediaEditModal('composer-a', 'm1'));

    expect(actions).toEqual(expect.arrayContaining([
      {
        type: INIT_MEDIA_EDIT_MODAL,
        id: 'm1',
        meta: { composerId: 'composer-a' },
      },
      {
        type: MODAL_OPEN,
        modalType: 'FOCAL_POINT',
        modalProps: { id: 'm1', composerId: 'composer-a' },
      },
    ]));
  });

  it('does not open the focal point modal for a missing composer', () => {
    const { store, actions } = makeStore();

    store.dispatch(initComposerMediaEditModal('missing', 'm1'));

    expect(actions.find(action => action.type === INIT_MEDIA_EDIT_MODAL)).toBeUndefined();
    expect(actions.find(action => action.type === MODAL_OPEN)).toBeUndefined();
  });

  it('does not open the focal point modal when the media is gone', () => {
    const { store, actions } = makeStore();
    store.dispatch(createComposer('composer-a'));

    store.dispatch(initComposerMediaEditModal('composer-a', 'm1'));

    expect(actions.find(action => action.type === INIT_MEDIA_EDIT_MODAL)).toBeUndefined();
    expect(actions.find(action => action.type === MODAL_OPEN)).toBeUndefined();
  });

  it('routes reply to the requested composer and keeps the primary wrapper on primary', () => {
    const { store, actions } = makeStore();
    store.dispatch(createComposer('composer-a'));

    store.dispatch(replyInComposer('composer-a', replyStatus, router));
    store.dispatch(replyCompose(replyStatus, router));

    expect(actions.find(action => action.type === COMPOSE_REPLY && action.meta && action.meta.composerId === 'composer-a')).toEqual(expect.objectContaining({
      type: COMPOSE_REPLY,
      meta: { composerId: 'composer-a' },
    }));
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'in_reply_to'])).toEqual('status-1');
    expect(store.getState().getIn(['compose', 'in_reply_to'])).toEqual('status-1');
  });

  it('routes quote, mention, and direct setup to the requested composer', () => {
    const account = fromJS({ id: 'acc-1', acct: 'alice' });
    const { store, actions } = makeStore();
    store.dispatch(createComposer('composer-a'));

    store.dispatch(quoteInComposer('composer-a', replyStatus, router));
    store.dispatch(mentionInComposer('composer-a', account, router));
    store.dispatch(directInComposer('composer-a', account, router));

    expect(actions.filter(action => ['COMPOSE_QUOTE', 'COMPOSE_MENTION', 'COMPOSE_DIRECT'].includes(action.type)).map(action => action.meta)).toEqual([
      { composerId: 'composer-a' },
      { composerId: 'composer-a' },
      { composerId: 'composer-a' },
    ]);
  });

  it('corrects visibility and adds a reference on the requested composer', () => {
    const { store, actions } = makeStore(ImmutableMap({
      statuses: ImmutableMap({
        'ref-1': fromJS({ id: 'ref-1', visibility: 'private' }),
      }),
    }));
    store.dispatch(createComposer('composer-a'));
    store.dispatch(targetComposerAction(changeComposeVisibility('public'), 'composer-a'));
    store.dispatch(changeComposeVisibility('unlisted'));

    store.dispatch(addReferenceToComposer('composer-a', 'ref-1', true));

    expect(actions.filter(action => action.type === COMPOSE_VISIBILITY_CHANGE && action.meta && action.meta.composerId === 'composer-a').map(action => action.value)).toEqual(['public', 'private']);
    expect(actions.find(action => action.type === COMPOSE_REFERENCE_ADD)).toEqual({
      type: COMPOSE_REFERENCE_ADD,
      id: 'ref-1',
      meta: { composerId: 'composer-a' },
    });
    expect(store.getState().getIn(['compose', 'privacy'])).toEqual('unlisted');
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'privacy'])).toEqual('private');
  });
});
