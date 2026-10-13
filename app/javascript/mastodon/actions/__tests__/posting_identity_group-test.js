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
import { changeCompose, changeComposeVisibility, submitComposer } from '../compose';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../composer';
import { PORTABLE_COMPOSER_MODE_SIMPLE, selectPortableComposerDisplayMode } from '../../selectors/composer';
import { resolveSenderIdentitySwitch } from '../../posting_identity/switch_resolver';
import { composerInteractionInputKey } from '../../posting_identity/interaction_input';
import { INTERACTION_CHECK_DELAY, selectComposerSenderIdentity } from '../posting_identities';
import { POSTING_CONTEXT_FETCH_SUCCESS } from '../posting_contexts';
import { postingContextCacheKey } from '../../selectors/posting_contexts';
import compose from '../../reducers/compose';
import { initialState as composerInitialState } from '../../reducers/composer';
import composers from '../../reducers/composers';
import postingContexts from '../../reducers/posting_contexts';
import postingIdentities from '../../reducers/posting_identities';
import settings from '../../reducers/settings';
import { selectComposerCanSendAsIdentity } from '../../selectors/posting_identities';

const reducer = combineReducers({
  compose,
  composers,
  postingIdentities,
  posting_contexts: postingContexts,
  timelines: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
  accounts: (state = ImmutableMap()) => state,
  settings,
});

const makeStore = preloadedState => createStore(reducer, preloadedState, applyMiddleware(thunk));

const readyIdentity = (id, capabilities = {}, delegationId = null) => fromJS({
  id,
  kind: id.startsWith('delegated:') ? 'delegated' : 'local',
  provider: 'fedibird',
  authorization: 'ready',
  account: { id: id.split(':')[1], acct: id.startsWith('delegated:') ? 'author' : 'admin', displayName: 'Name' },
  capabilities: {
    post: 'supported',
    media: 'supported',
    reply: 'unavailable',
    quote: 'unavailable',
    group: 'unavailable',
    schedule: 'unavailable',
    ...capabilities,
  },
  delegation: delegationId ? { id: delegationId, state: 'active', scopes: ['post', 'group'] } : null,
});

const groupContext = (accountId = '456') => ({
  key: `builtin:fedibird-group:${accountId}`,
  source: { id: 'builtin:fedibird-group', revision: 1 },
  managed: {
    hashtags: [],
    mentions: [{ accountId, acct: 'localsquad', enforcement: 'required', ruleId: 'group-account-mention' }],
  },
  requirements: {
    followingAccounts: [{ accountId, acct: 'localsquad', enforcement: 'required', ruleId: 'group-follow' }],
  },
  constraints: { allowedVisibilities: ['public', 'unlisted'] },
  protocol: { activityPub: { audience: null } },
});

const catalog = (identities, composeState = composerInitialState) => makeStore(ImmutableMap({
  postingIdentities: ImmutableMap({
    status: 'ready',
    defaultIdentityId: 'local:42',
    confirmedIdentityId: 'local:42',
    identities: ImmutableList(identities),
  }),
  compose: composeState,
  settings: ImmutableMap(),
}));

const applyGroup = (store, composerId, accountId = '456') => {
  store.dispatch(applyComposerPostingContext(composerId, groupContext(accountId), accountId));
};

const discovery = (accountId, delegationId, { following = true, canPost = true } = {}) => ({
  type: POSTING_CONTEXT_FETCH_SUCCESS,
  accountId,
  cacheKey: postingContextCacheKey(accountId, { identityId: 'delegated:99', delegationId }),
  receivedAt: Date.now(),
  data: {
    schema_version: 1,
    account_id: accountId,
    status: 'resolved',
    context: {
      key: `builtin:fedibird-group:${accountId}`,
      source: { id: 'builtin:fedibird-group', revision: 1 },
      managed: {
        hashtags: [],
        mentions: [{ account_id: accountId, acct: 'localsquad', enforcement: 'required', rule_id: 'group-account-mention' }],
      },
      requirements: {
        following_accounts: [{ account_id: accountId, acct: 'localsquad', enforcement: 'required', rule_id: 'group-follow' }],
      },
      constraints: { allowed_visibilities: ['public', 'unlisted'] },
    },
    discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
    sender_posting: {
      identity_id: 'delegated:99',
      delegation_id: delegationId,
      can_post: canPost,
      following,
    },
  },
});

describe('delegated local group posts', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    api.mockReset();
    api.mockReturnValue({
      post: jest.fn(() => Promise.resolve({ status: 204 })),
      get: jest.fn(() => new Promise(() => {})),
      request: jest.fn(() => Promise.resolve({ data: { id: '1', visibility: 'public', account: { id: '99' }, scheduled_at: null, tags: [] } })),
    });
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('selects a granted identity without dropping the group or the draft', async () => {
    const store = catalog([
      readyIdentity('local:42', { group: 'supported', reply: 'supported', quote: 'supported' }),
      readyIdentity('delegated:99', { group: 'supported' }, '7'),
    ]);
    const beforeKey = store.getState().getIn(['compose', 'idempotencyKey']);

    store.dispatch(targetComposerAction(changeComposeVisibility('public'), 'primary'));
    store.dispatch(changeCompose('Keep this draft'));
    applyGroup(store, 'primary');

    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    jest.advanceTimersByTime(INTERACTION_CHECK_DELAY);
    await Promise.resolve();

    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'privacy'])).toEqual('public');
    expect(store.getState().getIn(['compose', 'context', 'key'])).toEqual('builtin:fedibird-group:456');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).not.toEqual(beforeKey);
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').reason).toEqual('pending');

    store.dispatch(discovery('456', '7'));
    store.dispatch({
      type: 'COMPOSER_INTERACTION_CHECK_SUCCESS',
      identityId: 'delegated:99',
      epoch: store.getState().getIn(['compose', 'senderIdentity', 'changeEpoch']),
      delegationId: '7',
      inputKey: composerInteractionInputKey(store.getState().get('compose')),
      requestId: store.getState().getIn(['compose', 'interactionCheck', 'requestId']),
    });

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
  });

  it('refuses an identity without group scope and does not remove the destination', () => {
    const store = catalog([
      readyIdentity('local:42', { group: 'supported' }),
      readyIdentity('delegated:99', { group: 'unavailable' }, '7'),
    ]);

    store.dispatch(changeCompose('Keep this draft'));
    applyGroup(store, 'primary');
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));

    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('local:42');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'switchBlockReason'])).toEqual('group');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
  });

  it('blocks send when the granting account does not follow', () => {
    const composeState = composerInitialState
      .set('text', '@localsquad hello')
      .set('privacy', 'public')
      .set('posting_context_account_id', '456')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready');
    const store = catalog([
      readyIdentity('local:42', { group: 'supported' }),
      readyIdentity('delegated:99', { group: 'supported' }, '7'),
    ], composeState);

    applyGroup(store, 'primary');
    store.dispatch(discovery('456', '7', { following: false, canPost: false }));
    store.dispatch({
      type: 'COMPOSER_INTERACTION_CHECK_FAIL',
      identityId: 'delegated:99',
      epoch: 0,
      delegationId: '7',
      inputKey: composerInteractionInputKey(store.getState().get('compose')),
      requestId: 1,
    });
    store.dispatch({
      type: 'COMPOSER_INTERACTION_CHECK_REQUEST',
      identityId: 'delegated:99',
      epoch: 0,
      delegationId: '7',
      inputKey: composerInteractionInputKey(store.getState().get('compose')),
      requestId: 1,
    });
    store.dispatch({
      type: 'COMPOSER_INTERACTION_CHECK_FAIL',
      identityId: 'delegated:99',
      epoch: 0,
      delegationId: '7',
      inputKey: composerInteractionInputKey(store.getState().get('compose')),
      requestId: 1,
    });

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'follow',
    }));
    expect(store.getState().getIn(['compose', 'text'])).toEqual('@localsquad hello');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
  });

  it('drops a ready result when the group or the sender changes', async () => {
    const store = catalog([
      readyIdentity('local:42', { group: 'supported' }),
      readyIdentity('delegated:99', { group: 'supported' }, '7'),
      readyIdentity('delegated:100', { group: 'supported' }, '8'),
    ]);

    store.dispatch(targetComposerAction(changeComposeVisibility('public'), 'primary'));
    store.dispatch(changeCompose('Keep this draft'));
    applyGroup(store, 'primary');
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    jest.advanceTimersByTime(INTERACTION_CHECK_DELAY);
    await Promise.resolve();
    await Promise.resolve();
    store.dispatch(discovery('456', '7'));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);

    const stale = {
      type: 'COMPOSER_INTERACTION_CHECK_SUCCESS',
      identityId: 'delegated:99',
      epoch: store.getState().getIn(['compose', 'senderIdentity', 'changeEpoch']),
      delegationId: '7',
      inputKey: composerInteractionInputKey(store.getState().get('compose')),
      requestId: store.getState().getIn(['compose', 'interactionCheck', 'requestId']),
    };

    applyGroup(store, 'primary', '789');

    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('789');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(store.getState().getIn(['compose', 'interactionCheck', 'status'])).toEqual('pending');

    store.dispatch(stale);
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
  });

  it('refuses a switch that would keep another identity\'s media', () => {
    const blocked = resolveSenderIdentitySwitch({
      fromIdentityId: 'local:42',
      toIdentity: {
        id: 'delegated:99',
        kind: 'delegated',
        provider: 'fedibird',
        authorization: 'ready',
        registered: true,
        capabilities: { post: 'supported', group: 'supported', media: 'supported' },
      },
      sessionIdentityId: 'local:42',
      draft: {
        text: 'Keep this draft',
        senderStatus: 'ready',
        media: [{ id: 'pic', ownerIdentityId: 'local:42' }],
        idempotencyKey: 'before',
        contextKey: 'builtin:fedibird-group:456',
        postingContextAccountId: '456',
        resolvedAccountId: '456',
        userPostingContext: { privacy: 'public' },
        manual: {},
        postingContext: { locks: {} },
      },
      nextIdempotencyKey: 'after',
      confirmed: true,
    });
    const allowed = resolveSenderIdentitySwitch({
      fromIdentityId: 'local:42',
      toIdentity: blocked.toIdentityId ? {
        id: 'delegated:99',
        kind: 'delegated',
        provider: 'fedibird',
        authorization: 'ready',
        registered: true,
        capabilities: { post: 'supported', group: 'supported', media: 'supported' },
      } : null,
      sessionIdentityId: 'local:42',
      draft: {
        text: 'Keep this draft',
        senderStatus: 'ready',
        media: [{ id: 'pic', ownerIdentityId: 'delegated:99' }],
        idempotencyKey: 'before',
        contextKey: 'builtin:fedibird-group:456',
        postingContextAccountId: '456',
        resolvedAccountId: '456',
        userPostingContext: { privacy: 'public' },
        manual: {},
        postingContext: { locks: { privacy: 'public' } },
      },
      nextIdempotencyKey: 'after',
      confirmed: true,
    });

    expect(blocked.permitted).toBe(false);
    expect(blocked.reason).toEqual('media');
    expect(blocked.preservedText).toEqual('Keep this draft');
    expect(allowed.permitted).toBe(true);
    expect(allowed.keptMediaIds).toEqual(['pic']);
    expect(allowed.preservePostingStyle).toBe(true);
    expect(allowed.mustRevalidateGroup).toBe(true);
  });

  it('keeps the warning and sender available in primary, portable, and simple mode', async () => {
    const identities = [
      readyIdentity('local:42', { group: 'supported' }),
      readyIdentity('delegated:99', { group: 'supported' }, '7'),
    ];
    const store = catalog(identities);
    const portableId = 'portable:group-column:456';

    store.dispatch(createComposer(portableId));
    store.dispatch(changeCompose('Primary draft'));
    store.dispatch(targetComposerAction({ type: 'COMPOSE_CHANGE', text: 'Portable draft' }, portableId));
    applyGroup(store, 'primary');
    applyGroup(store, portableId);
    store.dispatch({
      type: 'SETTING_CHANGE',
      path: ['portableComposerDisplayMode', portableId],
      value: PORTABLE_COMPOSER_MODE_SIMPLE,
    });

    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));

    expect(store.getState().getIn(['compose', 'text'])).toEqual('Primary draft');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('Portable draft');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'posting_context_account_id'])).toEqual('456');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).canSend).toBe(false);

    const request = jest.fn(() => Promise.resolve({ data: { id: '9', visibility: 'public', account: { id: '99' }, tags: [] } }));

    api.mockReturnValue({ post: jest.fn(() => Promise.resolve({ status: 204 })), get: jest.fn(), request });
    await store.dispatch(submitComposer('primary'));

    expect(request).not.toHaveBeenCalled();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Primary draft');
    expect(selectPortableComposerDisplayMode(store.getState(), portableId)).toEqual(PORTABLE_COMPOSER_MODE_SIMPLE);
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).reason).toEqual('pending');
  });
});
