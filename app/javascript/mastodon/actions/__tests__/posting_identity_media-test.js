import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../initial_state', () => ({
  ...jest.requireActual('../../initial_state'),
  me: '42',
  isAdministrator: true,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import api from '../../api';
import { changeCompose, changeComposerUpload, submitComposer, uploadToComposer } from '../compose';
import { createComposer, destroyComposer, targetComposerAction } from '../composer';
import { POSTING_IDENTITIES_FETCH_SUCCESS, selectComposerSenderIdentity } from '../posting_identities';
import compose from '../../reducers/compose';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import postingIdentities from '../../reducers/posting_identities';
import { selectComposerCanSendAsIdentity, selectComposerCanUploadAsIdentity } from '../../selectors/posting_identities';

const reducer = combineReducers({
  compose,
  composers,
  postingIdentities,
  posting_contexts: (state = ImmutableMap()) => state,
  timelines: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
  accounts: (state = ImmutableMap()) => state,
});

const makeStore = (preloadedState) => createStore(reducer, preloadedState, applyMiddleware(thunk));

const router = {
  location: { pathname: '/home' },
  push: jest.fn(),
  goBack: jest.fn(),
};

const readyIdentity = (id, capabilities = {}) => fromJS({
  id,
  kind: id.startsWith('delegated:') ? 'delegated' : 'local',
  provider: 'fedibird',
  authorization: 'ready',
  account: { id: id.split(':')[1], acct: id.startsWith('delegated:') ? 'author' : 'admin', displayName: 'Name' },
  capabilities: {
    post: 'supported',
    media: 'supported',
    reply: 'unavailable',
    group: 'unavailable',
    schedule: 'unavailable',
    ...capabilities,
  },
});

const catalog = (identities) => makeStore(ImmutableMap({
  postingIdentities: ImmutableMap({
    status: 'ready',
    defaultIdentityId: 'local:42',
    confirmedIdentityId: 'local:42',
    identities: ImmutableList(identities),
  }),
}));

const delegatedStore = (capabilities = {}) => catalog([
  readyIdentity('local:42', { reply: 'supported', group: 'supported', schedule: 'supported' }),
  readyIdentity('delegated:99', capabilities),
]);

const flush = () => new Promise(resolve => setImmediate(resolve));

const statusBody = {
  id: 's1',
  visibility: 'public',
  in_reply_to_id: null,
  scheduled_at: null,
  tags: [],
  account: { id: '99' },
};

describe('delegated media composer', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('enables still-image upload only when the delegated sender has media permission', () => {
    const denied = delegatedStore({ media: 'unavailable' });

    denied.dispatch(changeCompose('Keep this draft'));
    denied.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));

    expect(selectComposerCanSendAsIdentity(denied.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: true,
      canUpload: false,
      reason: 'media',
    }));
    expect(selectComposerCanUploadAsIdentity(denied.getState(), 'primary')).toEqual(expect.objectContaining({
      canUpload: false,
      reason: 'media',
    }));

    const allowed = delegatedStore();

    allowed.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));

    expect(selectComposerCanUploadAsIdentity(allowed.getState(), 'primary')).toEqual({
      canUpload: true,
      reason: null,
      stillImagesOnly: true,
    });
    expect(selectComposerCanSendAsIdentity(allowed.getState(), 'primary').canSend).toBe(true);
  });

  it('uploads to the selected composer identity and leaves a normal upload unchanged', async () => {
    const post = jest.fn().mockResolvedValue({ status: 200, data: { id: 'm1', type: 'image' } });

    api.mockReturnValue({ post, get: jest.fn() });
    const store = delegatedStore();
    const portableId = 'portable:list-column:b';

    store.dispatch(createComposer(portableId));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));
    await store.dispatch(uploadToComposer(portableId, [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    await flush();

    expect(post).toHaveBeenCalledWith('/api/v2/media', expect.any(FormData), expect.any(Object));
    expect(post.mock.calls[0][1].get('posting_identity_id')).toEqual('delegated:99');
    expect(post.mock.calls[0][1].get('account_id')).toBeNull();
    expect(store.getState().getIn(['composers', 'byId', portableId, 'media_attachments']).map(item => item.get('id')).toArray()).toEqual(['m1']);
    expect(store.getState().getIn(['compose', 'media_attachments'])).toEqual(composer(undefined, { type: '@@INIT' }).get('media_attachments'));

    const localPost = jest.fn().mockResolvedValue({ status: 200, data: { id: 'local-media', type: 'image' } });

    api.mockReturnValue({ post: localPost, get: jest.fn() });
    await store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    await flush();

    expect(localPost.mock.calls[0][1].get('posting_identity_id')).toEqual('local:42');
    expect(store.getState().getIn(['compose', 'media_attachments']).first().get('id')).toEqual('local-media');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'media_attachments']).size).toBe(1);
  });

  it('refuses a sender change while a file is uploading or already attached', async () => {
    let resolvePost;
    const post = jest.fn().mockImplementation(() => new Promise(resolve => {
      resolvePost = resolve;
    }));

    api.mockReturnValue({ post, get: jest.fn() });
    const store = delegatedStore();

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'local:42', { confirmed: true }));
    store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));

    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'switchBlockReason'])).toEqual('media_uploading');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    resolvePost({ status: 200, data: { id: 'm1', type: 'image' } });
    await flush();
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));

    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'switchBlockReason'])).toEqual('media');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'media_attachments']).first().get('id')).toEqual('m1');
  });

  it('drops a stale processing response and a response for a destroyed composer', async () => {
    let resolvePost;
    let resolveGet;
    const post = jest.fn().mockImplementation(() => new Promise(resolve => {
      resolvePost = resolve;
    }));
    const get = jest.fn().mockImplementation(() => new Promise(resolve => {
      resolveGet = resolve;
    }));

    api.mockReturnValue({ post, get });
    const store = delegatedStore();
    const portableId = 'portable:list-column:b';

    store.dispatch(changeCompose('Primary text'));
    store.dispatch(createComposer(portableId));
    store.dispatch(targetComposerAction(changeCompose('Portable text'), portableId));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));
    store.dispatch(uploadToComposer(portableId, [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    resolvePost({ status: 202, data: { id: 'pending', type: 'image' } });
    await flush();

    expect(get).toHaveBeenCalledWith('/api/v1/media/pending', {
      params: { posting_identity_id: 'delegated:99' },
    });

    store.dispatch(targetComposerAction({
      type: 'COMPOSER_SENDER_IDENTITY_SELECT',
      decision: {
        permitted: true,
        effectsApplied: true,
        changing: true,
        toIdentityId: 'local:42',
        rotateIdempotencyKey: true,
        nextIdempotencyKey: 'next-key',
      },
    }, portableId));
    resolveGet({ status: 200, data: { id: 'pending', type: 'image' } });
    await flush();

    expect(store.getState().getIn(['composers', 'byId', portableId, 'media_attachments']).size).toBe(0);
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('Portable text');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'senderIdentity', 'id'])).toEqual('local:42');
    expect(store.getState().getIn(['compose', 'media_attachments']).size).toBe(0);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Primary text');

    store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    store.dispatch(destroyComposer(portableId));
    resolvePost({ status: 200, data: { id: 'late', type: 'image' } });
    await flush();

    expect(store.getState().getIn(['composers', 'byId', portableId])).toBeUndefined();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Primary text');
  });

  it('keeps the draft when processing fails or the delegation is no longer listed', async () => {
    const post = jest.fn()
      .mockResolvedValueOnce({ status: 202, data: { id: 'bad', type: 'image' } })
      .mockResolvedValueOnce({ status: 200, data: { id: 'kept', type: 'image' } });
    const get = jest.fn().mockRejectedValue({ response: { status: 403, data: { error: 'This action is not allowed' } } });

    api.mockReturnValue({ post, get, request: jest.fn() });
    const store = delegatedStore();

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    await flush();
    await flush();

    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'media_attachments']).size).toBe(0);
    expect(store.getState().getIn(['compose', 'is_uploading'])).toBe(false);
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');

    store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    await flush();
    store.dispatch({
      type: POSTING_IDENTITIES_FETCH_SUCCESS,
      defaultIdentityId: 'local:42',
      confirmedIdentityId: 'local:42',
      identities: ImmutableList([readyIdentity('local:42', { reply: 'supported', group: 'supported', schedule: 'supported' })]),
    });

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'unregistered',
    }));
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'media_attachments']).first().get('id')).toEqual('kept');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
  });

  it('sends an alt update with the composer identity and posts the still image as that sender', async () => {
    const post = jest.fn().mockResolvedValue({ status: 200, data: { id: 'm1', type: 'image' } });
    const put = jest.fn().mockResolvedValue({ data: { id: 'm1', type: 'image', description: 'Hill' } });
    const request = jest.fn().mockResolvedValue({ data: statusBody });

    api.mockReturnValue({ post, put, request, get: jest.fn() });
    const store = delegatedStore();
    const portableId = 'portable:list-column:b';

    store.dispatch(createComposer(portableId));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));
    store.dispatch(targetComposerAction(changeCompose('Portable text'), portableId));
    await store.dispatch(uploadToComposer(portableId, [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    await flush();
    store.dispatch(changeComposerUpload(portableId, 'm1', { description: 'Hill', focus: '0.20,-0.40' }));
    await flush();

    expect(put).toHaveBeenCalledWith('/api/v1/media/m1', expect.objectContaining({
      description: 'Hill',
      focus: '0.20,-0.40',
      posting_identity_id: 'delegated:99',
    }));
    expect(put.mock.calls[0][1].posting_identity_id).not.toEqual('local:42');

    const idempotencyKey = store.getState().getIn(['composers', 'byId', portableId, 'idempotencyKey']);

    await store.dispatch(submitComposer(portableId, router));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
      headers: { 'Idempotency-Key': idempotencyKey },
    }));
    expect(request.mock.calls[0][0].data.posting_identity_id).toEqual('delegated:99');
    const sentMediaIds = request.mock.calls[0][0].data.media_ids;
    expect(sentMediaIds.toArray ? sentMediaIds.toArray() : sentMediaIds).toEqual(['m1']);
    expect(request.mock.calls[0][0].data.account_id).toBeUndefined();
    expect(store.getState().getIn(['composers', 'byId', portableId, 'senderIdentity', 'id'])).toEqual('delegated:99');
  });

  it('refuses video and audio for a delegated sender and keeps the draft when posting fails', async () => {
    const request = jest.fn().mockRejectedValue({ response: { status: 422, data: { error: 'no' } } });
    const post = jest.fn();

    api.mockReturnValue({
      request,
      post,
      get: jest.fn().mockResolvedValue({ data: { identities: [], default_identity_id: 'local:42' } }),
    });
    const store = delegatedStore();

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    await store.dispatch(uploadToComposer('primary', [new File(['x'], 'clip.mp4', { type: 'video/mp4' })]));
    await store.dispatch(uploadToComposer('primary', [new File(['x'], 'clip.mp3', { type: 'audio/mpeg' })]));

    expect(post).not.toHaveBeenCalled();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    store.dispatch(targetComposerAction({
      type: 'COMPOSE_UPLOAD_SUCCESS',
      media: { id: 'video', type: 'video' },
      skipLoading: true,
    }, 'primary'));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'media_type',
    }));

    await store.dispatch(submitComposer('primary', router));

    expect(request).not.toHaveBeenCalled();

    store.dispatch(targetComposerAction({
      type: 'COMPOSE_UPLOAD_UNDO',
      media_id: 'video',
    }, 'primary'));
    store.dispatch(targetComposerAction({
      type: 'COMPOSE_UPLOAD_SUCCESS',
      media: { id: 'still', type: 'image' },
      skipLoading: true,
    }, 'primary'));

    await store.dispatch(submitComposer('primary', router));

    expect(request).toHaveBeenCalled();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'media_attachments']).map(item => item.get('id')).toArray()).toEqual(['still']);
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).toEqual(request.mock.calls[0][0].headers['Idempotency-Key']);
  });

  it('uses the same upload decision for a portable composer as for the primary composer', () => {
    const store = delegatedStore();
    const portableId = 'portable:list-column:b';

    store.dispatch(createComposer(portableId));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));

    expect(selectComposerCanUploadAsIdentity(store.getState(), portableId)).toEqual(
      selectComposerCanUploadAsIdentity(store.getState(), 'primary'),
    );
    expect(selectComposerCanUploadAsIdentity(store.getState(), portableId)).toEqual({
      canUpload: true,
      reason: null,
      stillImagesOnly: true,
    });
  });
});
