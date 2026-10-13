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
import { changeCompose, changeComposeSpoilerText, changeComposeSpoilerness, changeComposeVisibility, COMPOSE_QUOTE_CANCEL, COMPOSE_REPLY, COMPOSE_REPLY_CANCEL, COMPOSE_SUBMIT_SUCCESS, replyInComposer } from '../compose';
import { COMPOSER_INTERACTION_CHECK_SUCCESS, createComposer, targetComposerAction } from '../composer';
import { composerInteractionInputKey } from '../../posting_identity/interaction_input';
import { cancelComposerInteractionChecks, INTERACTION_CHECK_DELAY, retryComposerInteraction, scheduleComposerInteractionCheck, selectComposerSenderIdentity, validateComposerInteraction } from '../posting_identities';
import { PORTABLE_COMPOSER_MODE_SIMPLE } from '../../selectors/composer';
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
  settings: (state = ImmutableMap()) => state,
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

const withCheck = (composeState, status = 'ready') => composeState.set('interactionCheck', ImmutableMap({
  status,
  identityId: composeState.getIn(['senderIdentity', 'id']),
  epoch: Number(composeState.getIn(['senderIdentity', 'changeEpoch'])) || 0,
  inputKey: composerInteractionInputKey(composeState),
}));

describe('delegated replies and quotes', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    api.mockReset();
    api.mockReturnValue({
      post: jest.fn(() => new Promise(() => {})),
      get: jest.fn(() => Promise.resolve({ data: {} })),
    });
  });

  afterEach(() => {
    cancelComposerInteractionChecks();
    jest.useRealTimers();
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
      inputKey: 'stale',
    }, 'primary'));

    expect(store.getState().getIn(['compose', 'interactionCheck', 'status'])).toEqual('pending');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toContain('Portable draft');

    jest.advanceTimersByTime(INTERACTION_CHECK_DELAY);
    calls[0]({ status: 204 });
    await Promise.resolve();
    await Promise.resolve();

    expect(store.getState().getIn(['compose', 'interactionCheck', 'status'])).toEqual('ready');
    expect(store.getState().getIn(['compose', 'interactionCheck', 'inputKey'])).toEqual(
      composerInteractionInputKey(store.getState().get('compose')),
    );
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).canSend).toBe(false);
    expect(store.getState().getIn(['composers', 'byId', portableId, 'interactionCheck', 'status'])).toEqual('pending');
  });

  it('blocks send when the target is denied and keeps the draft after permission is lost', () => {
    const identities = [
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated(),
    ];
    const denied = catalog(identities, withCheck(composerInitialState
      .set('text', 'Keep this draft')
      .set('in_reply_to', 'status-1')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready'), 'denied'));

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
    ], withCheck(base.set('in_reply_to', 'status-1')));
    const quoteStore = catalog([
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated({ reply: 'unavailable', quote: 'supported' }),
    ], withCheck(base.set('quote_from', 'status-2')));
    const wrongQuote = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'supported', quote: 'unavailable' }),
    ], withCheck(base.set('quote_from', 'status-2')));
    const wrongReply = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'unavailable', quote: 'supported' }),
    ], withCheck(base.set('in_reply_to', 'status-1')));
    const foreignMedia = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'supported', media: 'supported' }),
    ], withCheck(base
      .set('in_reply_to', 'status-1')
      .set('media_attachments', ImmutableList([
        ImmutableMap({ id: 'm1', type: 'image', ownerIdentityId: 'local:42' }),
      ]))));
    const ownedMedia = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'supported', media: 'supported' }),
    ], withCheck(base
      .set('in_reply_to', 'status-1')
      .set('media_attachments', ImmutableList([
        ImmutableMap({ id: 'm1', type: 'image', ownerIdentityId: 'delegated:99' }),
      ]))));
    const grouped = catalog([
      readyIdentity('local:42'),
      delegated({ reply: 'supported', quote: 'supported' }),
    ], withCheck(base
      .set('in_reply_to', 'status-1')
      .set('posting_context_account_id', '456')));

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

  it('drops a ready check when the text, warning, or visibility changes and keeps the draft', async () => {
    const calls = [];
    const post = jest.fn(() => new Promise(resolve => {
      calls.push(resolve);
    }));
    api.mockReturnValue({ post, get: jest.fn(() => Promise.resolve({ data: {} })) });
    const identities = [
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated({ reply: 'supported', quote: 'supported' }),
    ];
    const ready = composeState => catalog(identities, withCheck(composeState
      .set('text', 'Keep this draft')
      .set('spoiler', true)
      .set('spoiler_text', 'warning')
      .set('privacy', 'public')
      .set('in_reply_to', 'status-1')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready')));
    const textChanged = ready(composerInitialState);

    expect(selectComposerCanSendAsIdentity(textChanged.getState(), 'primary').canSend).toBe(true);

    textChanged.dispatch(changeCompose('Keep this draft more'));

    expect(selectComposerCanSendAsIdentity(textChanged.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: false,
      reason: 'pending',
    }));
    expect(textChanged.getState().getIn(['compose', 'text'])).toEqual('Keep this draft more');

    const warned = ready(composerInitialState);
    warned.dispatch(changeComposeSpoilerText('warning changed'));

    expect(selectComposerCanSendAsIdentity(warned.getState(), 'primary').canSend).toBe(false);
    expect(warned.getState().getIn(['compose', 'spoiler_text'])).toEqual('warning changed');
    expect(warned.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    const narrowed = ready(composerInitialState);
    narrowed.dispatch(changeComposeVisibility('private'));

    expect(selectComposerCanSendAsIdentity(narrowed.getState(), 'primary').canSend).toBe(false);
    expect(narrowed.getState().getIn(['compose', 'privacy'])).toEqual('private');
    expect(narrowed.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');

    const portableId = 'portable:list:9';
    textChanged.dispatch(createComposer(portableId));
    textChanged.dispatch(targetComposerAction(changeCompose('Portable stays'), portableId));
    textChanged.dispatch(scheduleComposerInteractionCheck('primary'));
    textChanged.dispatch(scheduleComposerInteractionCheck('primary'));
    textChanged.dispatch(scheduleComposerInteractionCheck(portableId));

    expect(post).not.toHaveBeenCalled();
    jest.advanceTimersByTime(INTERACTION_CHECK_DELAY);

    expect(post).toHaveBeenCalledTimes(1);
    expect(post.mock.calls[0][1]).toEqual(expect.objectContaining({
      status: 'Keep this draft more',
      spoiler_text: 'warning',
      visibility: 'public',
      in_reply_to_id: 'status-1',
    }));

    textChanged.dispatch(targetComposerAction({
      type: COMPOSER_INTERACTION_CHECK_SUCCESS,
      identityId: 'delegated:99',
      epoch: 0,
      inputKey: composerInteractionInputKey(composerInitialState.set('text', 'Keep this draft')),
    }, 'primary'));

    expect(selectComposerCanSendAsIdentity(textChanged.getState(), 'primary').canSend).toBe(false);
    expect(textChanged.getState().getIn(['composers', 'byId', portableId, 'text'])).toEqual('Portable stays');

    calls[0]({ status: 204 });
    await Promise.resolve();
    await Promise.resolve();

    expect(selectComposerCanSendAsIdentity(textChanged.getState(), 'primary').canSend).toBe(true);
    expect(textChanged.getState().getIn(['compose', 'text'])).toEqual('Keep this draft more');

    post.mockImplementationOnce(() => Promise.reject(new Error('offline')));
    textChanged.dispatch(changeCompose('Keep this draft more'));
    textChanged.dispatch(retryComposerInteraction('primary'));
    await Promise.resolve();
    await Promise.resolve();

    expect(selectComposerCanSendAsIdentity(textChanged.getState(), 'primary').canSend).toBe(false);
    expect(textChanged.getState().getIn(['compose', 'text'])).toEqual('Keep this draft more');

    post.mockImplementationOnce(() => Promise.resolve({ status: 204 }));
    textChanged.dispatch(retryComposerInteraction('primary'));
    await Promise.resolve();
    await Promise.resolve();

    expect(selectComposerCanSendAsIdentity(textChanged.getState(), 'primary').canSend).toBe(true);
    expect(textChanged.getState().getIn(['compose', 'text'])).toEqual('Keep this draft more');
  });

  it('rechecks after the content warning is toggled and keeps the draft and sender', async () => {
    const calls = [];
    const post = jest.fn(() => new Promise(resolve => {
      calls.push(resolve);
    }));
    api.mockReturnValue({ post, get: jest.fn(() => Promise.resolve({ data: {} })) });
    const store = catalog([
      readyIdentity('local:42', { reply: 'supported' }),
      delegated({ reply: 'supported' }),
    ], withCheck(composerInitialState
      .set('text', 'Keep this draft')
      .set('spoiler', true)
      .set('spoiler_text', 'warning')
      .set('privacy', 'public')
      .set('in_reply_to', 'status-1')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready')));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);

    store.dispatch(changeComposeSpoilerness());
    store.dispatch(scheduleComposerInteractionCheck('primary'));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(post).not.toHaveBeenCalled();

    jest.advanceTimersByTime(INTERACTION_CHECK_DELAY);

    expect(post).toHaveBeenCalledTimes(1);
    expect(post.mock.calls[0][1].spoiler_text).toEqual('');
    expect(post.mock.calls[0][1].status).toEqual('Keep this draft');

    calls[0]({ status: 204 });
    await Promise.resolve();
    await Promise.resolve();

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Keep this draft');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
  });

  it('completes the check for a simple-mode portable composer', async () => {
    const calls = [];
    const post = jest.fn(() => new Promise(resolve => {
      calls.push(resolve);
    }));
    api.mockReturnValue({ post, get: jest.fn(() => Promise.resolve({ data: {} })) });
    const portableId = 'portable:list:simple';
    const store = makeStore(ImmutableMap({
      postingIdentities: ImmutableMap({
        status: 'ready',
        defaultIdentityId: 'local:42',
        confirmedIdentityId: 'local:42',
        identities: ImmutableList([
          readyIdentity('local:42', { reply: 'supported' }),
          delegated({ reply: 'supported' }),
        ]),
      }),
      settings: ImmutableMap({
        portableComposerDisplayMode: ImmutableMap({
          [portableId]: PORTABLE_COMPOSER_MODE_SIMPLE,
        }),
      }),
    }));

    store.dispatch(createComposer(portableId));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));
    store.dispatch(targetComposerAction(changeCompose('Simple draft'), portableId));
    store.dispatch(targetComposerAction({ type: COMPOSE_REPLY, status: replyStatus('status-1') }, portableId));
    store.dispatch(scheduleComposerInteractionCheck(portableId));
    jest.advanceTimersByTime(INTERACTION_CHECK_DELAY);

    expect(post).toHaveBeenCalledTimes(1);
    expect(post.mock.calls[0][1].posting_identity_id).toEqual('delegated:99');

    calls[0]({ status: 204 });
    await Promise.resolve();
    await Promise.resolve();

    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).canSend).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toContain('Simple draft');
    expect(store.getState().getIn(['composers', 'byId', portableId, 'senderIdentity', 'id'])).toEqual('delegated:99');
  });

  it('keeps only the latest check when two requests share an input and answers arrive reversed', async () => {
    const resolvers = [];
    const post = jest.fn(() => new Promise((resolve, reject) => {
      resolvers.push({ resolve, reject });
    }));
    api.mockReturnValue({ post, get: jest.fn(() => Promise.resolve({ data: {} })) });
    const store = catalog([
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated({ reply: 'supported', quote: 'supported' }),
    ]);
    const portableId = 'portable:list:9';

    store.dispatch(createComposer(portableId));
    store.dispatch(selectComposerSenderIdentity('primary', 'delegated:99', { confirmed: true }));
    store.dispatch(selectComposerSenderIdentity(portableId, 'delegated:99', { confirmed: true }));
    store.dispatch(changeCompose('Same text'));
    store.dispatch(targetComposerAction(changeCompose('Portable text'), portableId));
    store.dispatch(targetComposerAction({ type: COMPOSE_REPLY, status: replyStatus('status-1') }, 'primary'));
    store.dispatch(targetComposerAction({ type: COMPOSE_REPLY, status: replyStatus('status-9') }, portableId));

    const first = store.dispatch(validateComposerInteraction('primary'));
    const second = store.dispatch(validateComposerInteraction('primary'));
    const portable = store.dispatch(validateComposerInteraction(portableId));

    expect(post.mock.calls[0][1].status).toEqual(post.mock.calls[1][1].status);

    resolvers[1].resolve({ status: 204 });
    await second;
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);

    resolvers[0].reject(new Error('older failure'));
    await first;
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(store.getState().getIn(['compose', 'text'])).toContain('Same text');
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');

    resolvers[2].reject(new Error('portable failed'));
    await portable;
    expect(selectComposerCanSendAsIdentity(store.getState(), portableId).canSend).toBe(false);
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', portableId, 'text'])).toContain('Portable text');

    const failed = store.dispatch(validateComposerInteraction('primary'));
    const newer = store.dispatch(validateComposerInteraction('primary'));

    resolvers[4].reject(new Error('latest failed'));
    await newer;
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);

    resolvers[3].resolve({ status: 204 });
    await failed;
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);

    const original = store.getState().getIn(['compose', 'text']);
    const stale = store.dispatch(validateComposerInteraction('primary'));

    store.dispatch(changeCompose('Temporary'));
    store.dispatch(changeCompose(original));
    resolvers[5].resolve({ status: 204 });
    await stale;

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(false);
    expect(store.getState().getIn(['compose', 'text'])).toEqual(original);

    store.dispatch(retryComposerInteraction('primary'));
    resolvers[6].resolve({ status: 204 });
    await Promise.resolve();
    await Promise.resolve();

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
  });

  it('does not stay unable to send after a reply or quote is canceled', () => {
    const store = catalog([
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated({ reply: 'supported', quote: 'supported' }),
    ], withCheck(composerInitialState
      .set('text', 'Keep this draft')
      .set('in_reply_to', 'status-1')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready')));

    store.dispatch({ type: COMPOSE_REPLY_CANCEL });

    expect(store.getState().getIn(['compose', 'in_reply_to'])).toBeNull();
    expect(store.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);

    store.dispatch(targetComposerAction({
      type: COMPOSER_INTERACTION_CHECK_SUCCESS,
      identityId: 'delegated:99',
      epoch: 0,
      inputKey: 'old',
      requestId: 1,
    }, 'primary'));

    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary').canSend).toBe(true);

    const quoting = catalog([
      readyIdentity('local:42', { reply: 'supported', quote: 'supported' }),
      delegated({ reply: 'supported', quote: 'supported' }),
    ], withCheck(composerInitialState
      .set('text', 'Quoted draft')
      .set('quote_from', 'status-2')
      .setIn(['senderIdentity', 'id'], 'delegated:99')
      .setIn(['senderIdentity', 'status'], 'ready')));

    quoting.dispatch({ type: COMPOSE_QUOTE_CANCEL });

    expect(quoting.getState().getIn(['compose', 'quote_from'])).toBeNull();
    expect(quoting.getState().getIn(['compose', 'senderIdentity', 'id'])).toEqual('delegated:99');
    expect(selectComposerCanSendAsIdentity(quoting.getState(), 'primary').canSend).toBe(true);
  });
});
