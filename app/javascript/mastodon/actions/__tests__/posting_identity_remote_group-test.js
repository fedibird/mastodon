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
import { changeCompose, submitComposer } from '../compose';
import { createComposer } from '../composer';
import { INTERACTION_CHECK_DELAY, selectComposerSenderIdentity } from '../posting_identities';
import { commitUserPostingStyle } from '../user_posting_styles';
import { composerInteractionInputKey } from '../../posting_identity/interaction_input';
import { postingContextCacheKey } from '../../selectors/posting_contexts';
import { PORTABLE_COMPOSER_MODE_SIMPLE, selectPortableComposerDisplayMode } from '../../selectors/composer';
import { selectComposerCanSendAsIdentity } from '../../selectors/posting_identities';
import { selectComposerEffectiveCreateCapability } from '../../posting_context/create_capability';
import { initialState as composerInitialState } from '../../reducers/composer';
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
  settings,
  timelines: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
});

const identity = (id, delegationId, capabilities = {}) => fromJS({
  id,
  kind: id.startsWith('delegated:') ? 'delegated' : 'local',
  provider: 'fedibird',
  authorization: 'ready',
  account: { id: id.split(':')[1], acct: 'author', displayName: 'Author' },
  capabilities: {
    post: 'supported',
    media: 'supported',
    reply: 'unavailable',
    quote: 'unavailable',
    group: 'supported',
    schedule: 'unavailable',
    ...capabilities,
  },
  delegation: delegationId ? { id: String(delegationId), state: 'active', scopes: ['post', 'group'] } : null,
});

const mitraContext = (accountId = '456', revision = 1) => ({
  key: `protocol:fep-1b12-group:${accountId}`,
  source: { id: 'compat:mitra-fep-1b12', revision },
  resolvedAccountId: accountId,
  managed: { hashtags: [], mentions: [] },
  requirements: { followingAccounts: [] },
  constraints: { allowedVisibilities: ['public', 'unlisted'] },
  protocol: {
    activityPub: {
      audience: { accountId, acct: 'circle@mitra.example', enforcement: 'required', ruleId: 'fep-1b12-group-audience' },
    },
  },
});

const senderPosting = ({ canPost = true, confirmed = true, status = 'allowed', delegationId = '7', adapter = 'mitra_group', delivery = 'supported' } = {}) => ({
  identity_id: 'delegated:99',
  delegation_id: delegationId,
  can_post: canPost,
  permission: { status, confirmed, source: 'fep-5219', freshness: confirmed ? 'current' : 'absent' },
  delivery: { status: delivery, adapter, authority: 'compatibility' },
});

const discovery = (accountId, delegationId, posting) => ({
  type: 'POSTING_CONTEXT_FETCH_SUCCESS',
  accountId,
  cacheKey: postingContextCacheKey(accountId, { identityId: 'delegated:99', delegationId }),
  receivedAt: Date.now(),
  data: {
    schema_version: 1,
    account_id: accountId,
    status: 'resolved',
    context: {
      key: `protocol:fep-1b12-group:${accountId}`,
      source: { id: 'compat:mitra-fep-1b12', revision: 1 },
      managed: { hashtags: [], mentions: [] },
      requirements: { following_accounts: [] },
      constraints: { allowed_visibilities: ['public', 'unlisted'] },
      protocol: {
        activitypub: {
          audience: { account_id: accountId, acct: 'circle@mitra.example', enforcement: 'required', rule_id: 'fep-1b12-group-audience' },
        },
      },
    },
    discovery: { mechanism: 'nodeinfo_software', adapter: 'mitra_group', authority: 'compatibility' },
    sender_posting: posting,
  },
});

const readyCompose = (accountId = '456', revision = 1) => {
  const context = fromJS(mitraContext(accountId, revision));
  let composeState = composerInitialState
    .set('text', 'Keep this draft')
    .set('privacy', 'public')
    .set('posting_context_account_id', accountId)
    .set('context', context)
    .setIn(['senderIdentity', 'id'], 'delegated:99')
    .setIn(['senderIdentity', 'status'], 'ready');

  composeState = composeState.set('interactionCheck', ImmutableMap({
    status: 'ready',
    identityId: 'delegated:99',
    epoch: 0,
    delegationId: '7',
    inputKey: composerInteractionInputKey(composeState),
    requestId: 1,
  }));

  return composeState;
};

const makeStore = (composeState = readyCompose(), identities = [identity('local:42', null), identity('delegated:99', '7')]) => createStore(reducer, ImmutableMap({
  postingIdentities: ImmutableMap({
    status: 'ready',
    defaultIdentityId: 'local:42',
    confirmedIdentityId: 'local:42',
    identities: ImmutableList(identities),
  }),
  compose: composeState,
  settings: ImmutableMap(),
}), applyMiddleware(thunk));

describe('delegated Mitra group posts', () => {
  beforeEach(() => {
    api.mockReset();
    api.mockReturnValue({ request: jest.fn(() => Promise.resolve({ data: { id: '1', account: { id: '99' }, visibility: 'public', tags: [] } })), post: jest.fn(), get: jest.fn() });
  });

  it('can send when B canCreate is allowed and keeps the draft when it is unknown', () => {
    const allowed = makeStore();

    allowed.dispatch(discovery('456', '7', senderPosting()));

    expect(selectComposerCanSendAsIdentity(allowed.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerEffectiveCreateCapability(allowed.getState(), 'primary').canAttempt).toBe(true);

    const unknown = makeStore();

    unknown.dispatch(discovery('456', '7', senderPosting({ canPost: false, confirmed: false, status: 'unknown' })));

    expect(selectComposerCanSendAsIdentity(unknown.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'permission',
    }));
    expect(selectComposerEffectiveCreateCapability(unknown.getState(), 'primary').canAttempt).toBe(false);
    expect(unknown.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(unknown.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
  });

  it('does not reuse A evidence, an old delegation, or another group', () => {
    const store = makeStore();

    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '456',
      receivedAt: Date.now(),
      data: {
        schema_version: 1,
        account_id: '456',
        status: 'resolved',
        context: discovery('456', '7', null).data.context,
        discovery: { mechanism: 'nodeinfo_software', adapter: 'mitra_group', authority: 'compatibility' },
        viewer_evidence: {
          affiliations: { source: 'fep-5219-affiliations', snapshot_status: 'fresh', relationships: [] },
          permissions: { create: { status: 'allowed', source: 'fep-5219', via_relationship: 'none', authority: 'protocol' } },
        },
      },
    });

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);

    store.dispatch(discovery('456', '7', senderPosting()));
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);

    const moved = makeStore(readyCompose(), [identity('local:42', null), identity('delegated:99', '8')]);

    moved.dispatch(discovery('456', '7', senderPosting()));
    expect(selectComposerCanSendAsIdentity(moved.getState(), 'primary').canSend).toBe(false);
    expect(moved.getState().getIn(['posting_contexts', postingContextCacheKey('456', { identityId: 'delegated:99', delegationId: '7' }), 'senderPosting', 'canPost'])).toBe(true);

    const changed = makeStore(readyCompose('789'));

    changed.dispatch(discovery('456', '7', senderPosting()));
    expect(selectComposerCanSendAsIdentity(changed.getState(), 'primary').canSend).toBe(false);
    expect(changed.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(changed.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('789');
  });

  it('rejects a mismatched audience, a changed revision, and a reply', () => {
    const mismatched = readyCompose().setIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'], '999');
    const store = makeStore(mismatched);

    store.dispatch(discovery('456', '7', senderPosting()));
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').reason).toEqual('group');

    const revised = makeStore(readyCompose('456', 2));

    revised.dispatch(discovery('456', '7', senderPosting()));
    expect(selectComposerEffectiveCreateCapability(revised.getState(), 'primary').canAttempt).toBe(false);
    expect(revised.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    const reply = makeStore(readyCompose().set('in_reply_to', 'status-1'), [
      identity('local:42', null, { reply: 'supported' }),
      identity('delegated:99', '7', { reply: 'supported' }),
    ]);

    reply.dispatch(discovery('456', '7', senderPosting()));
    expect(selectComposerCanSendAsIdentity(reply.getState(), 'primary').reason).toEqual('group');
  });

  it('keeps primary, portable, and simple mode on the same permission and preserves a blocked draft', async () => {
    const portableId = 'portable:list:9';
    const portable = readyCompose().setIn(['senderIdentity', 'id'], 'delegated:99');
    const store = makeStore();

    store.dispatch(createComposer(portableId));
    store.dispatch({
      type: 'SETTING_CHANGE',
      path: ['portableComposerDisplayMode', portableId],
      value: PORTABLE_COMPOSER_MODE_SIMPLE,
    });
    store.dispatch(discovery('456', '7', senderPosting()));
    const request = jest.fn(() => Promise.resolve({ data: { id: '9', visibility: 'public', account: { id: '99' }, tags: [] } }));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerEffectiveCreateCapability(store.getState(), 'primary').canAttempt).toBe(true);
    api.mockReturnValue({ request, post: jest.fn(), get: jest.fn() });
    await store.dispatch(submitComposer('primary'));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({
        posting_identity_id: 'delegated:99',
        posting_context_account_id: '456',
        posting_context_key: 'protocol:fep-1b12-group:456',
        audience_account_id: '456',
        status: 'Keep this draft',
      }),
    }));
    expect(selectPortableComposerDisplayMode(store.getState(), portableId)).toEqual(PORTABLE_COMPOSER_MODE_SIMPLE);
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('');

    const blocked = makeStore(portable.set('text', 'Portable draft'));

    blocked.dispatch(discovery('456', '7', senderPosting({ canPost: false, confirmed: false, status: 'unknown' })));
    const blockedRequest = jest.fn();

    api.mockReturnValue({ request: blockedRequest, post: jest.fn(), get: jest.fn() });
    await blocked.dispatch(submitComposer('primary'));
    expect(blockedRequest).not.toHaveBeenCalled();
    expect(blocked.getState().getIn(['compose', 'text'])).toEqual('Portable draft');
    expect(blocked.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
    expect(selectComposerCanSendAsIdentity(blocked.getState(), 'primary').canSend).toBe(false);
    expect(selectComposerEffectiveCreateCapability(blocked.getState(), 'primary').canAttempt).toBe(false);
  });
});

const nodebbContext = (accountId = '456', acct = 'category@nodebb.example', revision = 1) => ({
  key: `protocol:fep-1b12-nodebb:${accountId}`,
  source: { id: 'compat:nodebb-fep-1b12', revision },
  resolvedAccountId: accountId,
  managed: {
    hashtags: [],
    mentions: [{ accountId, acct, enforcement: 'required', ruleId: 'nodebb-group-mention' }],
  },
  requirements: { followingAccounts: [] },
  constraints: { allowedVisibilities: ['public'] },
  protocol: {
    activityPub: {
      audience: { accountId, acct, enforcement: 'required', ruleId: 'fep-1b12-group-audience' },
    },
  },
});

const nodebbDiscovery = (accountId, delegationId, posting, acct = 'category@nodebb.example') => ({
  type: 'POSTING_CONTEXT_FETCH_SUCCESS',
  accountId,
  cacheKey: postingContextCacheKey(accountId, { identityId: 'delegated:99', delegationId }),
  receivedAt: Date.now(),
  data: {
    schema_version: 1,
    account_id: accountId,
    status: 'resolved',
    context: {
      key: `protocol:fep-1b12-nodebb:${accountId}`,
      source: { id: 'compat:nodebb-fep-1b12', revision: 1 },
      managed: {
        hashtags: [],
        mentions: [{ account_id: accountId, acct, enforcement: 'required', rule_id: 'nodebb-group-mention' }],
      },
      requirements: { following_accounts: [] },
      constraints: { allowed_visibilities: ['public'] },
      protocol: {
        activitypub: {
          audience: { account_id: accountId, acct, enforcement: 'required', rule_id: 'fep-1b12-group-audience' },
        },
      },
    },
    discovery: { mechanism: 'nodeinfo_software', adapter: 'nodebb_group', authority: 'compatibility' },
    sender_posting: posting,
  },
});

const readyNodebb = (accountId = '456', revision = 1, acct = 'category@nodebb.example') => {
  const context = fromJS(nodebbContext(accountId, acct, revision));
  let composeState = composerInitialState
    .set('text', 'Keep this draft')
    .set('privacy', 'public')
    .set('posting_context_account_id', accountId)
    .set('context', context)
    .setIn(['senderIdentity', 'id'], 'delegated:99')
    .setIn(['senderIdentity', 'status'], 'ready');

  composeState = composeState.set('interactionCheck', ImmutableMap({
    status: 'ready',
    identityId: 'delegated:99',
    epoch: 0,
    delegationId: '7',
    inputKey: composerInteractionInputKey(composeState),
    requestId: 1,
  }));

  return composeState;
};

describe('delegated NodeBB group posts', () => {
  beforeEach(() => {
    api.mockReset();
    api.mockReturnValue({ request: jest.fn(() => Promise.resolve({ data: { id: '1', account: { id: '99' }, visibility: 'public', tags: [] } })), post: jest.fn(), get: jest.fn() });
  });

  it('can send with post and group when B canCreate is allowed', async () => {
    const store = makeStore(readyNodebb());

    store.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group' })));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerEffectiveCreateCapability(store.getState(), 'primary').canAttempt).toBe(true);

    const request = jest.fn(() => Promise.resolve({ data: { id: '9', visibility: 'public', account: { id: '99' }, tags: [] } }));

    api.mockReturnValue({ request, post: jest.fn(), get: jest.fn() });
    await store.dispatch(submitComposer('primary'));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({
        posting_identity_id: 'delegated:99',
        posting_context_account_id: '456',
        posting_context_key: 'protocol:fep-1b12-nodebb:456',
        posting_context_revision: 1,
        audience_account_id: '456',
        status: '@category@nodebb.example Keep this draft',
      }),
    }));
  });

  it('cannot send when canCreate is unknown or the category mention cannot be placed', () => {
    const unknown = makeStore(readyNodebb());

    unknown.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group', canPost: false, confirmed: false, status: 'unknown' })));

    expect(selectComposerCanSendAsIdentity(unknown.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'permission',
    }));
    expect(selectComposerEffectiveCreateCapability(unknown.getState(), 'primary').canAttempt).toBe(false);
    expect(unknown.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(unknown.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');

    const missing = makeStore(readyNodebb('456', 1, ''));

    missing.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group' }), ''));

    expect(selectComposerCanSendAsIdentity(missing.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'mention',
    }));
    expect(missing.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
  });

  it('does not reuse another group, delegation, or a non-NodeBB adapter', () => {
    const changed = makeStore(readyNodebb('789'));

    changed.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group' })));
    expect(selectComposerCanSendAsIdentity(changed.getState(), 'primary').canSend).toBe(false);
    expect(changed.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('789');

    const moved = makeStore(readyNodebb(), [identity('local:42', null), identity('delegated:99', '8')]);

    moved.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group' })));
    expect(selectComposerCanSendAsIdentity(moved.getState(), 'primary').canSend).toBe(false);

    const lemmy = readyNodebb().setIn(['context', 'key'], 'protocol:fep-1b12-lemmy:456');
    const forged = makeStore(lemmy);

    forged.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'lemmy_group', delivery: 'supported' })));
    expect(selectComposerCanSendAsIdentity(forged.getState(), 'primary').reason).toEqual('group');
    expect(selectComposerEffectiveCreateCapability(forged.getState(), 'primary').canAttempt).toBe(false);
  });

  it('rejects a mismatched audience or revision and keeps a failed draft', async () => {
    const mismatched = readyNodebb().setIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'], '999');
    const store = makeStore(mismatched);

    store.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group' })));
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').reason).toEqual('group');

    const revised = makeStore(readyNodebb('456', 2));

    revised.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group' })));
    expect(selectComposerEffectiveCreateCapability(revised.getState(), 'primary').canAttempt).toBe(false);
    expect(revised.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    const failed = makeStore(readyNodebb());
    const request = jest.fn(() => Promise.reject({ response: { status: 422 } }));

    failed.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group' })));
    api.mockReturnValue({ request, post: jest.fn(), get: jest.fn(() => Promise.resolve({ data: {} })) });
    await failed.dispatch(submitComposer('primary'));

    expect(request).toHaveBeenCalled();
    expect(failed.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(failed.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
    expect(failed.getState().getIn(['compose', 'context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('456');
  });

  it('uses the same decision in primary, portable, and simple mode', () => {
    const portableId = 'portable:list:9';
    const store = makeStore(readyNodebb());

    store.dispatch(createComposer(portableId));
    store.dispatch({
      type: 'SETTING_CHANGE',
      path: ['portableComposerDisplayMode', portableId],
      value: PORTABLE_COMPOSER_MODE_SIMPLE,
    });
    store.dispatch(nodebbDiscovery('456', '7', senderPosting({ adapter: 'nodebb_group' })));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerEffectiveCreateCapability(store.getState(), 'primary').canAttempt).toBe(true);
    expect(selectPortableComposerDisplayMode(store.getState(), portableId)).toEqual(PORTABLE_COMPOSER_MODE_SIMPLE);
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('');
  });
});

const nodebbOrderReducer = combineReducers({
  compose,
  composers,
  postingIdentities,
  posting_contexts: postingContexts,
  relationships,
  settings,
  userPostingStyles,
});

const nodebbOrderDiscovery = (accountId, { delegated = false, delegationId = '7', canPost = true } = {}) => ({
  schema_version: 1,
  account_id: accountId,
  status: 'resolved',
  context: nodebbDiscovery(accountId, delegationId, null).data.context,
  discovery: { mechanism: 'nodeinfo_software', adapter: 'nodebb_group', authority: 'compatibility' },
  sender_posting: delegated ? senderPosting({ adapter: 'nodebb_group', canPost, confirmed: canPost, status: canPost ? 'allowed' : 'unknown', delegationId }) : undefined,
});

describe('delegated NodeBB group discovery order', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    api.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  const makeOrderStore = () => {
    const store = createStore(nodebbOrderReducer, applyMiddleware(thunk));

    store.dispatch({
      type: 'POSTING_IDENTITIES_FETCH_SUCCESS',
      defaultIdentityId: 'local:42',
      confirmedIdentityId: 'local:42',
      identities: [
        identity('local:42', null),
        identity('delegated:99', '7'),
      ],
    });
    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [fromJS({
        id: '1',
        name: 'category',
        icon: '📣',
        purpose: 'category',
        revision: 1,
        target: { kind: 'group', accountId: '456', hashtag: null, label: 'category' },
        defaults: { visibility: 'public' },
        managed: { hashtags: [] },
      })],
    });

    return store;
  };

  const flushInteraction = async () => {
    jest.advanceTimersByTime(INTERACTION_CHECK_DELAY);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  };

  it('can send after B is chosen and then the category style resolves', async () => {
    const get = jest.fn((url, config) => {
      const delegated = Boolean(config && config.params && config.params.posting_identity_id);

      return Promise.resolve({ data: nodebbOrderDiscovery('456', { delegated }) });
    });

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeOrderStore();

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    await store.dispatch(commitUserPostingStyle('primary', '1'));
    await flushInteraction();

    expect(get).toHaveBeenCalledWith(
      '/api/v1/fedibird/accounts/456/posting_context',
      { params: { posting_identity_id: 'delegated:99' } },
    );
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'context', 'key'])).toEqual('protocol:fep-1b12-nodebb:456');
    expect(store.getState().getIn(['compose', 'context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('456');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerEffectiveCreateCapability(store.getState(), 'primary').canAttempt).toBe(true);
  });

  it('can send after the category style is applied and then B is chosen', async () => {
    const get = jest.fn((url, config) => {
      const delegated = Boolean(config && config.params && config.params.posting_identity_id);

      return Promise.resolve({ data: nodebbOrderDiscovery('456', { delegated }) });
    });

    api.mockReturnValue({ get, post: jest.fn(() => Promise.resolve({ status: 204 })) });
    const store = makeOrderStore();

    store.dispatch(changeCompose('Keep this draft'));
    await store.dispatch(commitUserPostingStyle('primary', '1'));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    await Promise.resolve();
    await flushInteraction();

    expect(get).toHaveBeenCalledWith(
      '/api/v1/fedibird/accounts/456/posting_context',
      { params: { posting_identity_id: 'delegated:99' } },
    );
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
  });
});
