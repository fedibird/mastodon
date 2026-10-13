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
import { changeCompose, COMPOSE_REPLY, COMPOSE_SUBMIT_SUCCESS, replyInComposer } from '../compose';
import { COMPOSER_INTERACTION_CHECK_SUCCESS, createComposer, targetComposerAction } from '../composer';
import { selectComposerSenderIdentity } from '../posting_identities';
import compose from '../../reducers/compose';
import { initialState as composerInitialState } from '../../reducers/composer';
import composers from '../../reducers/composers';
import postingIdentities from '../../reducers/posting_identities';
import { selectComposerCanSendAsIdentity } from '../../selectors/posting_identities';

const reducer = combineReducers({
  compose,
  composers,
  postingIdentities,
  posting_contexts: (state = ImmutableMap()) => state,
  timelines: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
  accounts: (state = ImmutableMap()) => state,
});

const makeStore = preloadedState => createStore(reducer, preloadedState, applyMiddleware(thunk));

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
    quote: 'unavailable',
    group: 'unavailable',
    schedule: 'unavailable',
    ...capabilities,
  },
});

const replyStatus = (id = 'status-1') => fromJS({
  id,
  visibility: 'public',
  spoiler_text: '',
  language: 'en',
  mentions: [],
  status_reference_ids: [],
  in_reply_to_id: null,
  account: { id: '7', acct: 'speaker' },
});

const catalog = (identities, composeState = composerInitialState) => makeStore(ImmutableMap({
  postingIdentities: ImmutableMap({
    status: 'ready',
    defaultIdentityId: 'local:42',
    confirmedIdentityId: 'local:42',
    identities: ImmutableList(identities),
  }),
  compose: composeState,
}));

const delegated = (capabilities = { reply: 'supported', quote: 'supported' }) => readyIdentity('delegated:99', capabilities);

const check = (status, targetKey, epoch = 0, identityId = 'delegated:99') => ImmutableMap({
  status,
  identityId,
  epoch,
  targetKey,
});

describe('delegated replies and quotes', () => {
  beforeEach(() => {
    api.mockReset();
    api.mockReturnValue({
      post: jest.fn(() => new Promise(() => {})),
      get: jest.fn(() => Promise.resolve({ data: {} })),
    });
  });

  it('keeps a reply draft when the sender changes and while the target is unchecked', () => {
    const store = catalog([
      readyIdentity('local:42', { reply: 'supported', quote: 'supported', group: 'supported', schedule: 'supported' }),
      delegated(),
    ]);

    store.dispatch(changeCompose('Keep this draft'));
    store.dispatch(targetComposerAction({ type: COMPOSE_REPLY, status: replyStatus() }, 'primary'));

    expect(store.getState().getIn(['compose', 'text'])).toContain('Keep this draft');
    expect(store.getState().getIn(['compose', 'in_reply_to'])).toEqual('status-1');

    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));

    expect(store.getState().getIn(['compose', 'text'])).toContain('Keep this draft');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'pending',
    }));
  });

  it('ignores a stale interaction result and does not mix composers', async () => {
    const calls = [];
    api.mockReturnValue({
      post: jest.fn(() => new Promise(resolve => {
        calls.push(resolve);
      })),
      get: jest.fn(() => Promise.resolve({ data: {} })),
    });
    const store = catalog([
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated(),
    ]);
    const portableId = 'portable:list:9';

    store.dispatch(createComposer(portableId));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));
    store.dispatch(changeCompose('Primary draft'));
    store.dispatch(targetComposerAction(changeCompose('Portable draft'), portableId));
    store.dispatch(replyInComposer('primary', replyStatus('status-1')));
    store.dispatch(replyInComposer(portableId, replyStatus('status-9')));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').reason).toEqual('pending');
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).reason).toEqual('pending');

    store.dispatch(targetComposerAction({
      type: COMPOSER_INTERACTION_CHECK_SUCCESS,
      identityId: 'delegated:99',
      epoch: 0,
      targetKey: 'status-1:',
    }, 'primary'));

    expect(store.getState().getIn(['compose', 'interactionCheck', 'status'])).toEqual('pending');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toContain('Portable draft');

    calls[0]({ status: 204 });
    await Promise.resolve();
    await Promise.resolve();

    expect(store.getState().getIn(['compose', 'interactionCheck', 'status'])).toEqual('ready');
    expect(store.getState().getIn(['compose', 'interactionCheck', 'targetKey'])).toEqual('status-1:');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).canSend).toBe(false);
    expect(store.getState().getIn(['composers', 'byId', portableId, 'interactionCheck', 'status'])).toEqual('pending');
  });

  it('blocks send when the target is denied and keeps the draft after permission is lost', () => {
    const identities = [
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated(),
    ];
    const denied = catalog(identities, composerInitialState
      .set('text', 'Keep this draft')
      .set('in_reply_to', 'status-1')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready')
      .set('interactionCheck', check('denied', 'status-1:')));

    expect(selectComposerCanSendAsIdentity(denied.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'target',
    }));
    expect(denied.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    const revoked = catalog([
      readyIdentity('local:42', { reply: 'supported' }),
      delegated().set('authorization', 'unavailable'),
    ], composerInitialState
      .set('text', 'Keep this draft')
      .set('in_reply_to', 'status-1')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready'));

    expect(selectComposerCanSendAsIdentity(revoked.getState(), 'primary').canSend).toBe(false);
    expect(revoked.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
  });

  it('separates reply, quote, media ownership, and group destinations', () => {
    const base = composerInitialState
      .set('text', 'Hello')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready');
    const replyStore = catalog([
      readyIdentity('local:42', { reply: 'supported' }),
      delegated({ reply: 'supported', quote: 'unavailable', media: 'supported' }),
    ], base
      .set('in_reply_to', 'status-1')
      .set('interactionCheck', check('ready', 'status-1:')));
    const quoteStore = catalog([
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated({ reply: 'unavailable', quote: 'supported' }),
    ], base
      .set('quote_from', 'status-2')
      .set('interactionCheck', check('ready', ':status-2')));
    const wrongQuote = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'supported', quote: 'unavailable' }),
    ], base
      .set('quote_from', 'status-2')
      .set('interactionCheck', check('ready', ':status-2')));
    const wrongReply = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'unavailable', quote: 'supported' }),
    ], base
      .set('in_reply_to', 'status-1')
      .set('interactionCheck', check('ready', 'status-1:')));
    const foreignMedia = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'supported', media: 'supported' }),
    ], base
      .set('in_reply_to', 'status-1')
      .set('interactionCheck', check('ready', 'status-1:'))
      .set('media_attachments', ImmutableList([
        ImmutableMap({ id: 'm1', type: 'image', ownerIdentityId: 'local:42' }),
      ])));
    const ownedMedia = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'supported', media: 'supported' }),
    ], base
      .set('in_reply_to', 'status-1')
      .set('interactionCheck', check('ready', 'status-1:'))
      .set('media_attachments', ImmutableList([
        ImmutableMap({ id: 'm1', type: 'image', ownerIdentityId: 'delegated:99' }),
      ])));
    const grouped = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'supported', quote: 'supported' }),
    ], base
      .set('in_reply_to', 'status-1')
      .set('interactionCheck', check('ready', 'status-1:'))
      .set('posting_context_account_id', '456'));

    expect(selectComposerCanSendAsIdentity(replyStore.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerCanSendAsIdentity(quoteStore.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerCanSendAsIdentity(wrongQuote.getState(), 'primary').reason).toEqual('quote');
    expect(selectComposerCanSendAsIdentity(wrongReply.getState(), 'primary').reason).toEqual('reply');
    expect(selectComposerCanSendAsIdentity(foreignMedia.getState(), 'primary').reason).toEqual('media_owner');
    expect(selectComposerCanSendAsIdentity(ownedMedia.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerCanSendAsIdentity(grouped.getState(), 'primary').reason).toEqual('group');
    expect(grouped.getState().getIn(['compose', 'text'])).toEqual('Hello');
  });

  it('clears the primary and portable composers after a successful reply', () => {
    const store = catalog([
      readyIdentity('local:42', { reply: 'supported' }),
      delegated({ reply: 'supported' }),
    ]);
    const portableId = 'portable:list:9';

    store.dispatch(createComposer(portableId));
    store.dispatch(changeCompose('Primary draft'));
    store.dispatch(targetComposerAction(changeCompose('Portable draft'), portableId));
    store.dispatch(targetComposerAction({ type: COMPOSE_REPLY, status: replyStatus('status-1') }, 'primary'));
    store.dispatch(targetComposerAction({ type: COMPOSE_REPLY, status: replyStatus('status-9') }, portableId));
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS });
    store.dispatch(targetComposerAction({ type: COMPOSE_SUBMIT_SUCCESS }, portableId));

    expect(store.getState().getIn(['compose', 'text'])).toEqual('');
    expect(store.getState().getIn(['compose', 'in_reply_to'])).toBeNull();
    expect(store.getState().getIn(['compose', 'interactionCheck'])).toBeNull();
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'in_reply_to'])).toBeNull();
    expect(store.getState().getIn(['composers', 'byId', portableId, 'quote_from'])).toBeNull();
  });
});
