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
import { submitComposer } from '../compose';
import { createComposer } from '../composer';
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
import settings from '../../reducers/settings';

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
