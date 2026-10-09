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
import { changeCompose, changeComposerUpload, changeComposeVisibility, submitComposer, uploadComposerThumbnail, uploadToComposer } from '../compose';
import { applyComposerPostingContext, COMPOSER_SENDER_IDENTITY_SELECT, createComposer, targetComposerAction } from '../composer';
import { fetchPostingIdentities, POSTING_IDENTITIES_FETCH_SUCCESS, selectComposerSenderIdentity } from '../posting_identities';
import compose from '../../reducers/compose';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import postingIdentities from '../../reducers/posting_identities';
import { selectComposerCanSendAsIdentity, selectComposerSenderIdentity as selectSender } from '../../selectors/posting_identities';

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

const readyIdentity = (id, authorization = 'ready') => fromJS({
  id,
  kind: 'local',
  provider: 'fedibird',
  authorization,
  account: { id: id.split(':')[1], acct: 'admin', displayName: 'Admin' },
  capabilities: {
    post: authorization === 'ready' ? 'supported' : 'unavailable',
    media: authorization === 'ready' ? 'supported' : 'unavailable',
    reply: authorization === 'ready' ? 'supported' : 'unavailable',
    group: authorization === 'ready' ? 'supported' : 'unavailable',
    schedule: authorization === 'ready' ? 'supported' : 'unavailable',
  },
});

const catalogState = (identities, status = 'ready', confirmedIdentityId = 'local:42') => makeStore(ImmutableMap({
  postingIdentities: ImmutableMap({
    status,
    defaultIdentityId: 'local:42',
    confirmedIdentityId,
    identities: ImmutableList(identities),
  }),
}));

const grant = store => {
  store.dispatch({
    type: POSTING_IDENTITIES_FETCH_SUCCESS,
    defaultIdentityId: 'local:42',
    confirmedIdentityId: 'local:42',
    identities: ImmutableList([readyIdentity('local:42')]),
  });
};

const statusBody = {
  id: 's1',
  visibility: 'public',
  in_reply_to_id: null,
  scheduled_at: null,
  tags: [],
  account: { id: '42' },
};

describe('composer sender identity', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('initializes the primary composer as the signed-in account', () => {
    const state = composer(undefined, { type: '@@INIT' });

    expect(state.getIn(['senderIdentity', 'id'])).toEqual('local:42');
    expect(state.getIn(['senderIdentity', 'selectionOrigin'])).toEqual('default');
    expect(state.getIn(['senderIdentity', 'status'])).toEqual('ready');
    expect(state.getIn(['senderIdentity', 'changeEpoch'])).toEqual(0);
    expect(state.get('text')).toEqual('');
    expect(state.getIn(['context', 'key'])).toBeNull();
    expect(state.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('initializes a portable composer independently with the same signed-in account', () => {
    const registry = composers(undefined, createComposer('portable:group-column:1'));
    const portable = registry.getIn(['byId', 'portable:group-column:1']);

    expect(portable.getIn(['senderIdentity', 'id'])).toEqual('local:42');
    expect(portable.getIn(['senderIdentity', 'selectionOrigin'])).toEqual('default');
    expect(portable.get('text')).toEqual('');
    expect(portable.getIn(['context', 'key'])).toBeNull();
  });

  it('keeps sender state, text, style, and posting context local to one composer', () => {
    const store = makeStore();

    store.dispatch(createComposer('portable:list-column:a'));
    store.dispatch(createComposer('portable:list-column:b'));
    store.dispatch(targetComposerAction(changeCompose('Alpha'), 'portable:list-column:a'));
    store.dispatch(targetComposerAction(changeCompose('Beta'), 'portable:list-column:b'));
    store.dispatch(applyComposerPostingContext('portable:list-column:a', {
      key: 'place:a',
      managed: { hashtags: [], mentions: [] },
      requirements: { followingAccounts: [] },
      constraints: { allowedVisibilities: ['public'] },
    }, null));

    const before = store.getState();
    const text = before.getIn(['composers', 'byId', 'portable:list-column:a', 'text']);
    const contextKey = before.getIn(['composers', 'byId', 'portable:list-column:a', 'context', 'key']);
    const styleId = before.getIn(['composers', 'byId', 'portable:list-column:a', 'userPostingStyle', 'selectedId']);

    store.dispatch(selectComposerSenderIdentity('portable:list-column:a', 'local:999'));

    const after = store.getState();

    expect(after.getIn(['composers', 'byId', 'portable:list-column:a', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(after.getIn(['composers', 'byId', 'portable:list-column:a', 'text'])).toEqual(text);
    expect(after.getIn(['composers', 'byId', 'portable:list-column:a', 'context', 'key'])).toEqual(contextKey);
    expect(after.getIn(['composers', 'byId', 'portable:list-column:a', 'userPostingStyle', 'selectedId'])).toEqual(styleId);
    expect(after.getIn(['composers', 'byId', 'portable:list-column:b', 'text'])).toEqual('Beta');
    expect(after.getIn(['composers', 'byId', 'portable:list-column:b', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(after.getIn(['compose', 'text'])).toEqual('');
  });

  it('does not apply an identity that is not in the catalog', () => {
    const store = catalogState([readyIdentity('local:42')]);

    store.dispatch(targetComposerAction(changeCompose('Still here'), 'primary'));
    store.dispatch(selectComposerSenderIdentity('primary', 'external:misskey'));

    expect(selectSender(store.getState(), 'primary').get('id')).toEqual('local:42');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Still here');
    expect(store.getState().getIn(['compose', 'context', 'key'])).toBeNull();
  });

  it('does not post when the catalog account or capability does not match', () => {
    const mismatched = readyIdentity('local:42').setIn(['account', 'id'], '999');
    const unsupported = readyIdentity('local:42').setIn(['capabilities', 'post'], 'unavailable');
    const mismatchStore = catalogState([mismatched]);
    const unsupportedStore = catalogState([unsupported]);

    expect(selectComposerCanSendAsIdentity(mismatchStore.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'mismatch',
    }));
    expect(selectComposerCanSendAsIdentity(unsupportedStore.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'unsupported',
    }));
  });

  it('does not post or upload for an unauthorized identity', async () => {
    const request = jest.fn();
    const post = jest.fn();

    api.mockReturnValue({ request, post });
    const store = catalogState([readyIdentity('local:42', 'unavailable')], 'ready', null);

    store.dispatch(changeCompose('Hello'));
    await store.dispatch(submitComposer('primary', router));
    store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'unauthorized',
    }));
    expect(request).not.toHaveBeenCalled();
    expect(post).not.toHaveBeenCalled();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Hello');
  });

  it('does not treat a failed identity lookup as permission to post', async () => {
    const request = jest.fn();

    api.mockReturnValue({
      request,
      get: jest.fn().mockRejectedValue(new Error('offline')),
    });
    const store = makeStore();

    store.dispatch(changeCompose('Hello'));
    await store.dispatch(fetchPostingIdentities());
    await store.dispatch(submitComposer('primary', router));

    expect(store.getState().getIn(['postingIdentities', 'status'])).toEqual('failed');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(request).not.toHaveBeenCalled();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Hello');
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('does not post from an administrator composer before the catalog is ready', async () => {
    const request = jest.fn();

    api.mockReturnValue({ request });
    const store = makeStore();

    store.dispatch(createComposer('portable:group-column:9'));
    store.dispatch(changeCompose('Hello session'));
    store.dispatch(targetComposerAction(changeCompose('Portable hello'), 'portable:group-column:9'));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'idle',
    }));
    expect(selectComposerCanSendAsIdentity(store.getState(), 'portable:group-column:9').canSend).toBe(false);

    store.dispatch({
      type: POSTING_IDENTITIES_FETCH_SUCCESS,
      defaultIdentityId: null,
      confirmedIdentityId: null,
      identities: ImmutableList(),
    });
    store.dispatch({ type: 'POSTING_IDENTITIES_FETCH_REQUEST' });

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').reason).toEqual('loading');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'portable:group-column:9').canSend).toBe(false);

    await store.dispatch(submitComposer('primary', router));
    await store.dispatch(submitComposer('portable:group-column:9', router));
    store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));

    expect(request).not.toHaveBeenCalled();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Hello session');
    expect(store.getState().getIn(['composers', 'byId', 'portable:group-column:9', 'text'])).toEqual('Portable hello');
  });

  it('posts again after the catalog is confirmed', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusBody });
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce({
        data: {
          default_identity_id: 'local:42',
          identities: [{
            id: 'local:42',
            kind: 'local',
            provider: 'fedibird',
            authorization: 'ready',
            account: { id: '42', acct: 'admin', display_name: 'Admin' },
            capabilities: {
              post: 'supported',
              media: 'supported',
              reply: 'supported',
              group: 'supported',
              schedule: 'supported',
            },
          }],
        },
      });

    api.mockReturnValue({ request, get });
    const store = makeStore();

    store.dispatch(changeCompose('Hello session'));
    await store.dispatch(fetchPostingIdentities());

    expect(store.getState().getIn(['postingIdentities', 'status'])).toEqual('failed');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);

    await store.dispatch(fetchPostingIdentities({ force: true }));
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: true,
      canUpload: true,
    }));

    await store.dispatch(submitComposer('primary', router));

    expect(request).toHaveBeenCalledTimes(1);
  });

  it('does not apply a described sender change to the draft', () => {
    const store = catalogState([readyIdentity('local:42')]);

    store.dispatch(changeCompose('Keep this draft'));

    const idempotencyKey = store.getState().getIn(['compose', 'idempotencyKey']);
    store.dispatch(targetComposerAction({
      type: COMPOSER_SENDER_IDENTITY_SELECT,
      decision: {
        permitted: true,
        changing: true,
        discardMedia: true,
        keptMediaIds: [],
        rotateIdempotencyKey: true,
        nextIdempotencyKey: 'replaced-key',
        toIdentityId: 'local:42',
      },
    }, 'primary'));

    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).toEqual(idempotencyKey);
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('local:42');
  });

  it('posts the primary composer through the current session', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusBody });

    api.mockReturnValue({ request });
    const store = makeStore();

    grant(store);
    store.dispatch(changeCompose('Hello session'));
    await store.dispatch(submitComposer('primary', router));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(request.mock.calls[0][0].data.status).toEqual('Hello session');
    expect(request.mock.calls[0][0].data.posting_identity_id).toEqual('local:42');
    expect(request.mock.calls[0][0].data.account_id).toBeUndefined();
  });

  it('keeps a portable composer destination when the sender is the signed-in account', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusBody });

    api.mockReturnValue({ request });
    const store = makeStore();

    grant(store);
    store.dispatch(changeCompose('Primary stays'));
    store.dispatch(createComposer('portable:group-column:123'));
    store.dispatch(targetComposerAction(changeCompose('Group hello'), 'portable:group-column:123'));
    store.dispatch(targetComposerAction(changeComposeVisibility('public'), 'portable:group-column:123'));
    store.dispatch(applyComposerPostingContext('portable:group-column:123', {
      key: 'builtin:fedibird-group:123',
      managed: { hashtags: [], mentions: [] },
      requirements: { followingAccounts: [] },
      constraints: { allowedVisibilities: ['public', 'unlisted'] },
      protocol: {
        activityPub: {
          audience: { accountId: '123', acct: 'group' },
        },
      },
    }, null));

    await store.dispatch(submitComposer('portable:group-column:123', router));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(request.mock.calls[0][0].data.status).toEqual('Group hello');
    expect(request.mock.calls[0][0].data.audience_account_id).toEqual('123');
    expect(request.mock.calls[0][0].data.posting_identity_id).toEqual('local:42');
    expect(request.mock.calls[0][0].data.account_id).toBeUndefined();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Primary stays');
    expect(store.getState().getIn(['composers', 'byId', 'portable:group-column:123', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
    expect(store.getState().getIn(['composers', 'byId', 'portable:group-column:123', 'context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('123');
  });

  it('does not treat a delegated catalog entry as a sender that can post', () => {
    const delegated = readyIdentity('delegated:99', 'unavailable').set('kind', 'delegated').setIn(['account', 'id'], '99');
    const store = catalogState([readyIdentity('local:42'), delegated]);

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: true,
    }));

    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99'));

    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('');
  });

  it('keeps the draft and switches only the requested composer to a delegated sender', () => {
    const delegated = readyIdentity('delegated:99').set('kind', 'delegated').setIn(['account', 'id'], '99').setIn(['account', 'acct'], 'author').setIn(['capabilities', 'media'], 'unavailable').setIn(['capabilities', 'reply'], 'unavailable').setIn(['capabilities', 'group'], 'unavailable').setIn(['capabilities', 'schedule'], 'unavailable');
    const store = catalogState([readyIdentity('local:42'), delegated]);

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(createComposer('portable:list-column:b'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));

    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).not.toEqual(null);
    expect(store.getState().getIn(['composers', 'byId', 'portable:list-column:b', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: true,
      canUpload: false,
    }));
  });

  it('sends the signed-in identity with media upload, thumbnail, and description updates', async () => {
    const post = jest.fn().mockResolvedValue({ status: 200, data: { id: 'm1', type: 'image' } });
    const put = jest.fn().mockResolvedValue({ data: { id: 'm1', type: 'image', description: 'alt' } });

    api.mockReturnValue({ post, put });
    const store = makeStore();

    grant(store);
    await store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));
    store.dispatch(uploadComposerThumbnail('primary', 'm1', new File(['t'], 't.jpg', { type: 'image/jpeg' })));
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'alt' }));

    expect(post).toHaveBeenCalledWith('/api/v2/media', expect.any(FormData), expect.any(Object));
    expect(post.mock.calls[0][1].get('posting_identity_id')).toEqual('local:42');
    expect(post.mock.calls[0][1].get('account_id')).toBeNull();
    expect(put.mock.calls[0][0]).toEqual('/api/v1/media/m1');
    expect(put.mock.calls[0][1].get('posting_identity_id')).toEqual('local:42');
    expect(put.mock.calls[1][1]).toEqual(expect.objectContaining({
      description: 'alt',
      posting_identity_id: 'local:42',
    }));
    expect(put.mock.calls[1][1].account_id).toBeUndefined();
  });
});
