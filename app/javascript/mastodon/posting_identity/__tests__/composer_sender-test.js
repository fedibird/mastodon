import { Map as ImmutableMap, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../initial_state', () => ({
  me: '123',
  isAdministrator: true,
  disablePost: false,
  postReferenceModal: false,
  missingAltTextModal: false,
  enableFederatedTimeline: false,
  allowPollImage: true,
  maxAttachments: 4,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../../actions/importer', () => ({
  importFetchedAccounts: jest.fn(),
  importFetchedStatus: jest.fn(status => ({ type: 'STATUS_IMPORT', status })),
}));

jest.mock('../../actions/timelines', () => ({
  updateTimeline: jest.fn((timelineId, status) => ({ type: 'TIMELINE_UPDATE', timelineId, status })),
}));

jest.mock('../../selectors', () => ({
  getHomeVisibilities: () => ['public'],
  getLimitedVisibilities: () => ['private'],
}));

import api from '../../api';
import { changeCompose, submitComposer, uploadToComposer } from '../../actions/compose';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../../actions/composer';
import { POSTING_IDENTITIES_FETCH_FAIL, POSTING_IDENTITIES_FETCH_SUCCESS, selectComposerSenderIdentity } from '../../actions/posting_identities';
import compose from '../../reducers/compose';
import composers from '../../reducers/composers';
import postingIdentities from '../../reducers/posting_identities';
import { selectComposer } from '../../selectors/composer';
import { selectComposerCanSendAsIdentity, selectComposerCanUploadAsIdentity, selectComposerSenderIdentity as selectSender } from '../../selectors/posting_identity';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const reducer = combineReducers({
  compose,
  composers,
  postingIdentities,
  accounts: (state = ImmutableMap()) => state,
  timelines: (state = ImmutableMap({
    home: ImmutableMap({ items: ImmutableMap(), online: false }),
  })) => state,
  meta: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
});

const makeStore = () => createStore(reducer, applyMiddleware(thunk));

const readyIdentity = (id, accountId, authorization = 'ready') => fromJS({
  id,
  kind: 'local',
  provider: 'fedibird',
  account: {
    id: String(accountId),
    acct: 'admin',
    display_name: 'Admin',
    avatar: '/avatar',
    avatar_static: '/avatar-static',
  },
  authorization,
  capabilities: {
    post: authorization === 'ready' ? 'supported' : 'unavailable',
    media: authorization === 'ready' ? 'supported' : 'unavailable',
    reply: authorization === 'ready' ? 'supported' : 'unavailable',
    group: authorization === 'ready' ? 'supported' : 'unavailable',
    schedule: authorization === 'ready' ? 'supported' : 'unavailable',
  },
});

const grant = (...identities) => ({
  type: POSTING_IDENTITIES_FETCH_SUCCESS,
  defaultIdentityId: 'local:123',
  identities,
});

const statusResponse = {
  id: 's1',
  visibility: 'public',
  in_reply_to_id: null,
  scheduled_at: null,
  tags: [],
  account: { id: '123' },
};

describe('composer sender identity', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('initializes the primary composer as the signed-in local identity', () => {
    const sender = selectSender(makeStore().getState(), PRIMARY_COMPOSER_ID);

    expect(sender.toJS()).toEqual({
      id: 'local:123',
      selectionOrigin: 'default',
      status: 'ready',
      changeEpoch: 0,
    });
    expect(selectComposer(makeStore().getState(), PRIMARY_COMPOSER_ID).get('text')).toBe('');
  });

  it('initializes a portable composer as the signed-in local identity', () => {
    const store = makeStore();
    const composerId = 'portable:group-column:9';

    store.dispatch(createComposer(composerId, { default_privacy: 'public' }));

    const composer = selectComposer(store.getState(), composerId);

    expect(composer.getIn(['senderIdentity', 'id'])).toBe('local:123');
    expect(composer.getIn(['senderIdentity', 'selectionOrigin'])).toBe('default');
    expect(composer.getIn(['senderIdentity', 'status'])).toBe('ready');
    expect(composer.get('text')).toBe('');
    expect(composer.get('privacy')).toBe('public');
  });

  it('keeps sender state independent for each composer id', () => {
    const store = makeStore();

    store.dispatch(createComposer('composer-a', { default_privacy: 'public' }));
    store.dispatch(createComposer('composer-b', { default_privacy: 'private' }));
    store.dispatch(grant(readyIdentity('local:123', '123')));
    store.dispatch(targetComposerAction(changeCompose('only a'), 'composer-a'));
    store.dispatch(selectComposerSenderIdentity('composer-a', 'local:123'));

    const first = selectComposer(store.getState(), 'composer-a');
    const second = selectComposer(store.getState(), 'composer-b');

    expect(first.get('text')).toBe('only a');
    expect(second.get('text')).toBe('');
    expect(first.getIn(['senderIdentity', 'selectionOrigin'])).toBe('selected');
    expect(second.getIn(['senderIdentity', 'selectionOrigin'])).toBe('default');
    expect(first.get('senderIdentity')).not.toBe(second.get('senderIdentity'));
    expect(second.get('privacy')).toBe('private');
  });

  it('does not apply an identity that is not granted to the signed-in account', () => {
    const store = makeStore();
    const composerId = 'composer-a';

    store.dispatch(createComposer(composerId, { default_privacy: 'public' }));
    store.dispatch(targetComposerAction(changeCompose('keep'), composerId));
    store.dispatch(applyComposerPostingContext(composerId, { key: 'group:9' }, '456'));
    store.dispatch(grant(
      readyIdentity('local:123', '123'),
      readyIdentity('local:999', '999'),
    ));

    const before = selectComposer(store.getState(), composerId);

    store.dispatch(selectComposerSenderIdentity(composerId, 'local:999'));
    store.dispatch(selectComposerSenderIdentity(composerId, 'bluesky:alice'));
    store.dispatch(selectComposerSenderIdentity(composerId, 'missing'));

    const after = selectComposer(store.getState(), composerId);

    expect(after.getIn(['senderIdentity', 'id'])).toBe('local:123');
    expect(after.get('text')).toBe('keep');
    expect(after.get('posting_context_account_id')).toBe('456');
    expect(after.getIn(['context', 'key'])).toBe(before.getIn(['context', 'key']));
    expect(after.get('userPostingStyle')).toEqual(before.get('userPostingStyle'));
  });

  it('does not post or upload as an identity that is not ready', async () => {
    const store = makeStore();
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    const post = jest.fn().mockResolvedValue({ status: 200, data: { id: 'm1', type: 'image' } });

    api.mockReturnValue({ request, post });
    store.dispatch(targetComposerAction(changeCompose('hello'), PRIMARY_COMPOSER_ID));
    store.dispatch(grant(readyIdentity('local:123', '123', 'restricted')));

    const composer = selectComposer(store.getState(), PRIMARY_COMPOSER_ID);

    expect(composer.get('text')).toBe('hello');
    expect(composer.getIn(['senderIdentity', 'status'])).toBe('restricted');
    expect(selectComposerCanSendAsIdentity(store.getState(), PRIMARY_COMPOSER_ID)).toBe(false);
    expect(selectComposerCanUploadAsIdentity(store.getState(), PRIMARY_COMPOSER_ID)).toBe(false);

    await store.dispatch(submitComposer(PRIMARY_COMPOSER_ID, { push: jest.fn(), goBack: jest.fn(), location: { pathname: '/home' } }));
    await store.dispatch(uploadToComposer(PRIMARY_COMPOSER_ID, [{ size: 4, name: 'a.png' }]));

    expect(request).not.toHaveBeenCalled();
    expect(post).not.toHaveBeenCalled();
  });

  it('does not treat a failed identity lookup as permission to post', async () => {
    const store = makeStore();
    const request = jest.fn();

    api.mockReturnValue({ request });
    store.dispatch(createComposer('portable:list-column:1', { default_privacy: 'public' }));
    store.dispatch(targetComposerAction(changeCompose('hello'), 'portable:list-column:1'));
    store.dispatch(applyComposerPostingContext('portable:list-column:1', { key: 'hashtag:ruby' }, null));
    store.dispatch({ type: POSTING_IDENTITIES_FETCH_FAIL });

    const composer = selectComposer(store.getState(), 'portable:list-column:1');

    expect(composer.getIn(['senderIdentity', 'status'])).toBe('unresolved');
    expect(composer.get('text')).toBe('hello');
    expect(selectComposer(store.getState(), PRIMARY_COMPOSER_ID).getIn(['senderIdentity', 'status'])).toBe('unresolved');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'portable:list-column:1')).toBe(false);
    expect(store.getState().getIn(['postingIdentities', 'status'])).toBe('failed');

    await store.dispatch(submitComposer('portable:list-column:1', { push: jest.fn(), goBack: jest.fn(), location: { pathname: '/home' } }));

    expect(request).not.toHaveBeenCalled();
    expect(composer.getIn(['context', 'key'])).toBe(selectComposer(store.getState(), 'portable:list-column:1').getIn(['context', 'key']));
  });

  it('posts the primary composer through the signed-in session when the local identity is ready', async () => {
    const store = makeStore();
    const request = jest.fn().mockResolvedValue({ data: statusResponse });

    api.mockReturnValue({ request });
    store.dispatch(targetComposerAction(changeCompose('hello'), PRIMARY_COMPOSER_ID));
    store.dispatch(grant(readyIdentity('local:123', '123')));

    await store.dispatch(submitComposer(PRIMARY_COMPOSER_ID, { push: jest.fn(), goBack: jest.fn(), location: { pathname: '/home' } }));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(request.mock.calls[0][0].data.account_id).toBeUndefined();
    expect(request.mock.calls[0][0].data.status).toBe('hello');
  });

  it('keeps a portable composer destination fixed while the sender stays the signed-in account', async () => {
    const store = makeStore();
    const composerId = 'portable:group-column:9';
    const request = jest.fn().mockResolvedValue({ data: statusResponse });

    api.mockReturnValue({ request });
    store.dispatch(createComposer(composerId, { default_privacy: 'public' }));
    store.dispatch(targetComposerAction(changeCompose('hello group'), composerId));
    store.dispatch(applyComposerPostingContext(composerId, { key: 'builtin:group:9' }, '456'));
    store.dispatch(grant(readyIdentity('local:123', '123')));
    store.dispatch(selectComposerSenderIdentity(composerId, 'local:999'));

    const composer = selectComposer(store.getState(), composerId);

    expect(composer.get('posting_context_account_id')).toBe('456');
    expect(composer.getIn(['context', 'key'])).toBe('builtin:group:9');
    expect(composer.getIn(['senderIdentity', 'id'])).toBe('local:123');
    expect(composer.get('text')).toBe('hello group');

    store.dispatch(createComposer('portable:list-column:2', { default_privacy: 'unlisted' }));
    store.dispatch(targetComposerAction(changeCompose('hello list'), 'portable:list-column:2'));
    await store.dispatch(submitComposer('portable:list-column:2', { push: jest.fn(), goBack: jest.fn(), location: { pathname: '/lists/2' } }));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(request.mock.calls[0][0].data.account_id).toBeUndefined();
    expect(request.mock.calls[0][0].data.status).toBe('hello list');
    expect(selectComposer(store.getState(), composerId).get('posting_context_account_id')).toBe('456');
    expect(selectComposer(store.getState(), 'portable:list-column:2').getIn(['senderIdentity', 'id'])).toBe('local:123');
  });

  it('uploads media for the signed-in identity and still posts to the session media endpoint', async () => {
    const store = makeStore();
    const post = jest.fn().mockResolvedValue({ status: 200, data: { id: 'm1', type: 'unknown' } });

    api.mockReturnValue({ post });
    store.dispatch(grant(readyIdentity('local:123', '123')));

    await store.dispatch(uploadToComposer(PRIMARY_COMPOSER_ID, [new File(['x'], 'a.png', { type: 'image/png' })]));

    expect(post).toHaveBeenCalledWith('/api/v2/media', expect.any(FormData), expect.any(Object));
  });
});
