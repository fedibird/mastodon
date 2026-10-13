import { fromJS } from 'immutable';
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
import { changeCompose } from '../compose';
import { createComposer, targetComposerAction } from '../composer';
import { INTERACTION_CHECK_DELAY, selectComposerSenderIdentity } from '../posting_identities';
import { commitUserPostingStyle } from '../user_posting_styles';
import { postingContextCacheKey } from '../../selectors/posting_contexts';
import { PORTABLE_COMPOSER_MODE_SIMPLE, selectPortableComposerDisplayMode } from '../../selectors/composer';
import { selectComposerCanSendAsIdentity } from '../../selectors/posting_identities';
import { selectComposerEffectiveCreateCapability } from '../../posting_context/create_capability';
import compose from '../../reducers/compose';
import composers from '../../reducers/composers';
import postingContexts from '../../reducers/posting_contexts';
import postingIdentities from '../../reducers/posting_identities';
import relationships from '../../reducers/relationships';
import settings from '../../reducers/settings';
import userPostingStyles from '../../reducers/user_posting_styles';

const reducer = combineReducers({
  compose,
  composers,
  postingIdentities,
  posting_contexts: postingContexts,
  relationships,
  settings,
  userPostingStyles,
});

const identity = (id, capabilities, delegationId) => fromJS({
  id,
  kind: id.startsWith('delegated:') ? 'delegated' : 'local',
  provider: 'fedibird',
  authorization: 'ready',
  account: { id: id.split(':')[1], acct: id.startsWith('delegated:') ? 'author' : 'admin', displayName: 'Name' },
  capabilities: {
    post: 'supported',
    media: 'supported',
    reply: 'supported',
    quote: 'supported',
    group: 'supported',
    schedule: 'supported',
    ...capabilities,
  },
  delegation: delegationId ? { id: String(delegationId), state: 'active', scopes: ['post', 'group'] } : null,
});

const groupStyle = (id, accountId, label) => fromJS({
  id,
  name: label,
  icon: '📣',
  purpose: label,
  revision: 1,
  target: { kind: 'group', accountId, hashtag: null, label },
  defaults: { visibility: 'public' },
  managed: { hashtags: [] },
});

const discoveryBody = (accountId, { following = true, canPost = true, delegated = false, delegationId = '7' } = {}) => ({
  schema_version: 1,
  account_id: accountId,
  status: 'resolved',
  context: {
    key: `builtin:fedibird-group:${accountId}`,
    source: { id: 'builtin:fedibird-group', revision: 1 },
    managed: {
      hashtags: [],
      mentions: [{ account_id: accountId, acct: accountId === '123' ? 'localsquad' : 'othersquad', enforcement: 'required', rule_id: 'group-account-mention' }],
    },
    requirements: {
      following_accounts: [{ account_id: accountId, acct: accountId === '123' ? 'localsquad' : 'othersquad', enforcement: 'required', rule_id: 'group-follow' }],
    },
    constraints: { allowed_visibilities: ['public', 'unlisted'] },
  },
  discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
  sender_posting: delegated ? {
    identity_id: 'delegated:99',
    delegation_id: delegationId,
    can_post: canPost,
    following,
  } : undefined,
});

const makeStore = () => {
  const store = createStore(reducer, applyMiddleware(thunk));

  store.dispatch({
    type: 'POSTING_IDENTITIES_FETCH_SUCCESS',
    defaultIdentityId: 'local:42',
    confirmedIdentityId: 'local:42',
    identities: [
      identity('local:42'),
      identity('delegated:99', { group: 'supported' }, '7'),
    ],
  });
  store.dispatch({
    type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
    styles: [groupStyle('1', '123', 'localsquad'), groupStyle('2', '456', 'othersquad')],
  });

  return store;
};

const flushInteraction = async () => {
  jest.advanceTimersByTime(INTERACTION_CHECK_DELAY);
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

describe('delegated group discovery', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    api.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('can send after B is chosen and then the group style resolves B', async () => {
    const get = jest.fn((url, config) => {
      const delegated = Boolean(config && config.params && config.params.posting_identity_id);
      const accountId = url.split('/accounts/')[1].split('/')[0];

      return Promise.resolve({ data: discoveryBody(accountId, { delegated, following: true, canPost: true }) });
    });

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    await store.dispatch(commitUserPostingStyle('primary', '1'));
    await flushInteraction();

    expect(get).toHaveBeenCalledWith(
      '/api/v1/fedibird/accounts/123/posting_context',
      { params: { posting_identity_id: 'delegated:99' } },
    );
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('123');
    expect(store.getState().getIn(['posting_contexts', '123', 'senderPosting'])).toBeNull();
    expect(store.getState().getIn(['posting_contexts', postingContextCacheKey('123', { identityId: 'delegated:99', delegationId: '7' }), 'senderPosting', 'canPost'])).toBe(true);
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerEffectiveCreateCapability(store.getState(), 'primary').canAttempt).toBe(true);
  });

  it('can send after the group style is applied and then B is chosen', async () => {
    const get = jest.fn((url, config) => {
      const delegated = Boolean(config && config.params && config.params.posting_identity_id);
      const accountId = url.split('/accounts/')[1].split('/')[0];

      return Promise.resolve({ data: discoveryBody(accountId, { delegated, following: true, canPost: true }) });
    });

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();

    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: false, requested: false }],
    });
    store.dispatch(changeCompose('Keep this draft'));
    await store.dispatch(commitUserPostingStyle('primary', '1'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    await Promise.resolve();
    await flushInteraction();

    expect(get).toHaveBeenCalledWith(
      '/api/v1/fedibird/accounts/123/posting_context',
      { params: { posting_identity_id: 'delegated:99' } },
    );
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('123');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
  });

  it('cannot send when B does not follow, even if A does', async () => {
    const get = jest.fn((url, config) => {
      const delegated = Boolean(config && config.params && config.params.posting_identity_id);

      return Promise.resolve({ data: discoveryBody('123', { delegated, following: false, canPost: false }) });
    });

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();

    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });
    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    await store.dispatch(commitUserPostingStyle('primary', '1'));
    await flushInteraction();

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'follow',
    }));
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
  });

  it('does not let A discovery authorize B', async () => {
    let resolveDelegated;
    const get = jest.fn(() => new Promise(resolve => {
      resolveDelegated = resolve;
    }));

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();

    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '123',
      receivedAt: Date.now(),
      data: discoveryBody('123'),
    });
    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });
    store.dispatch(changeCompose('Keep this draft'));
    await store.dispatch(commitUserPostingStyle('primary', '1'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(store.getState().getIn(['posting_contexts', '123', 'senderPosting'])).toBeNull();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('123');
    resolveDelegated({ data: discoveryBody('123', { delegated: true }) });
  });

  it('rejects a session discovery that finishes after the sender becomes B', async () => {
    const pending = [];
    const get = jest.fn((url, config) => new Promise(resolve => {
      pending.push({ resolve, delegated: Boolean(config && config.params) });
    }));

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();

    store.dispatch(changeCompose('Keep this draft'));
    const first = store.dispatch(commitUserPostingStyle('primary', '1'));

    await Promise.resolve();
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    pending[0].resolve({ data: discoveryBody('123', { delegated: false, following: true, canPost: true }) });
    await first;

    const delegatedKey = postingContextCacheKey('123', { identityId: 'delegated:99', delegationId: '7' });

    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(store.getState().getIn(['posting_contexts', delegatedKey, 'status'])).not.toEqual('resolved');
    expect(store.getState().getIn(['posting_contexts', '123', 'senderPosting'])).toBeNull();

    pending.slice(1).forEach(item => item.resolve({ data: discoveryBody('123', { delegated: true }) }));
    await Promise.resolve();
  });

  it('rejects a delegated discovery that finishes after the sender returns to A', async () => {
    const pending = [];
    const get = jest.fn(() => new Promise(resolve => {
      pending.push(resolve);
    }));

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    const first = store.dispatch(commitUserPostingStyle('primary', '1'));

    await Promise.resolve();
    store.dispatch(selectComposerSenderIdentity('primary', 'local:42', { confirmed: true }));
    pending[0]({ data: discoveryBody('123', { delegated: true, following: true, canPost: true }) });
    await first;

    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'context', 'key'])).toBeNull();
    expect(store.getState().getIn(['posting_contexts', '123', 'senderPosting'])).toBeNull();

    pending.slice(1).forEach(resolve => resolve({ data: discoveryBody('123') }));
    await Promise.resolve();
  });

  it('does not apply the previous group when the destination changes during discovery', async () => {
    const pending = [];
    const get = jest.fn(() => new Promise(resolve => {
      pending.push(resolve);
    }));

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();

    store.dispatch(changeCompose('Keep this draft'));
    const first = store.dispatch(commitUserPostingStyle('primary', '1'));

    await Promise.resolve();
    const second = store.dispatch(commitUserPostingStyle('primary', '2'));

    pending[0]({ data: discoveryBody('123') });
    await first;

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toEqual('2');
    expect(store.getState().getIn(['compose', 'context', 'key'])).not.toEqual('builtin:fedibird-group:123');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    pending[1]({ data: discoveryBody('456') });
    await second;

    expect(store.getState().getIn(['compose', 'context', 'key'])).toEqual('builtin:fedibird-group:456');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
  });

  it('keeps primary and portable discovery state apart', async () => {
    const pending = [];
    const get = jest.fn((url, config) => new Promise(resolve => {
      pending.push({ resolve, delegated: Boolean(config && config.params && config.params.posting_identity_id) });
    }));

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();
    const portableId = 'portable:list:9';

    store.dispatch(createComposer(portableId));
    store.dispatch(changeCompose('Primary draft'));
    store.dispatch(targetComposerAction(changeCompose('Portable draft'), portableId));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));
    expect(store.getState().getIn(['composers', 'byId', portableId, 'senderIdentity', 'id'])).toEqual('delegated:99');
    const primary = store.dispatch(commitUserPostingStyle('primary', '1'));
    const portable = store.dispatch(commitUserPostingStyle(portableId, '1'));

    await Promise.resolve();
    const session = pending.find(item => !item.delegated);
    const delegated = pending.find(item => item.delegated);

    session.resolve({ data: discoveryBody('123') });
    await primary;

    expect(store.getState().getIn(['compose', 'text'])).toEqual('Primary draft');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('Portable draft');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'userPostingStyle', 'destinationStatus'])).toEqual('pending');
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).canSend).toBe(false);

    delegated.resolve({ data: discoveryBody('123', { delegated: true }) });
    await portable;
    await flushInteraction();

    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('Portable draft');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Primary draft');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).canSend).toBe(true);
    expect(selectComposerEffectiveCreateCapability(store.getState(), 'primary').canAttempt).toBe(false);
  });

  it('uses the same send decision in simple mode', async () => {
    const get = jest.fn((url, config) => {
      const delegated = Boolean(config && config.params && config.params.posting_identity_id);

      return Promise.resolve({ data: discoveryBody('123', { delegated }) });
    });

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();
    const portableId = 'portable:list:9';

    store.dispatch(createComposer(portableId));
    store.dispatch({
      type: 'SETTING_CHANGE',
      path: ['portableComposerDisplayMode', portableId],
      value: PORTABLE_COMPOSER_MODE_SIMPLE,
    });
    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(targetComposerAction(changeCompose('Keep this draft'), portableId));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));
    await store.dispatch(commitUserPostingStyle(portableId, '1'));
    await flushInteraction();

    expect(selectPortableComposerDisplayMode(store.getState(), portableId)).toEqual(PORTABLE_COMPOSER_MODE_SIMPLE);
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).canSend).toBe(true);
    expect(selectComposerEffectiveCreateCapability(store.getState(), portableId).canAttempt).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'posting_context_account_id'])).toEqual('123');
  });

  it('stays unable to send when B discovery fails', async () => {
    api.mockReturnValue({
      get: jest.fn(() => Promise.reject(new Error('offline'))),
      post: jest.fn(() => Promise.resolve({ status: 204 })),
    });
    const store = makeStore();

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    await store.dispatch(commitUserPostingStyle('primary', '1'));

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('failed');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
  });

  it('drops a cached grant when the delegation id changes and blocks a failed discovery', async () => {
    const get = jest.fn()
      .mockResolvedValueOnce({ data: discoveryBody('123', { delegated: true, delegationId: '7' }) })
      .mockRejectedValueOnce(new Error('offline'));

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeStore();

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    await store.dispatch(commitUserPostingStyle('primary', '1'));
    await flushInteraction();

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);

    store.dispatch({
      type: 'POSTING_IDENTITIES_FETCH_SUCCESS',
      defaultIdentityId: 'local:42',
      confirmedIdentityId: 'local:42',
      identities: [
        identity('local:42'),
        identity('delegated:99', { group: 'supported' }, '8'),
      ],
    });

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(store.getState().getIn(['posting_contexts', postingContextCacheKey('123', { identityId: 'delegated:99', delegationId: '7' }), 'senderPosting', 'canPost'])).toBe(true);
    expect(store.getState().getIn(['posting_contexts', postingContextCacheKey('123', { identityId: 'delegated:99', delegationId: '8' })])).toBeUndefined();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    store.dispatch({
      type: 'POSTING_IDENTITIES_FETCH_SUCCESS',
      defaultIdentityId: 'local:42',
      confirmedIdentityId: 'local:42',
      identities: [
        identity('local:42'),
        identity('delegated:99', { group: 'unavailable' }, '7').set('authorization', 'unavailable'),
      ],
    });

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(store.getState().getIn(['compose', 'context', 'key'])).toEqual('builtin:fedibird-group:123');
  });
});
