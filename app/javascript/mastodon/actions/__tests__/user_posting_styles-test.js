import { Map as ImmutableMap, fromJS } from 'immutable';
import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';
import { combineReducers } from 'redux-immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(() => ({
    get: jest.fn(() => Promise.reject(new Error('discovery should use the cache'))),
  })),
}));

import api from '../../api';
import { COMPOSE_LANGUAGE_CHANGE, COMPOSE_POLL_ADD, COMPOSE_QUOTE, COMPOSE_QUOTE_CANCEL, COMPOSE_REPLY, COMPOSE_REPLY_CANCEL, COMPOSE_UPLOAD_SUCCESS, COMPOSE_VISIBILITY_CHANGE, changeCompose } from '../compose';
import { commitUserPostingStyle, fetchUserPostingStyles, resolveUserPostingStyleDestination, retryUserPostingStyleDestination, toggleUserPostingStyleHashtag } from '../user_posting_styles';
import { POSTING_CONTEXT_FETCH_SUCCESS } from '../posting_contexts';
import { selectComposerPostingContextCompliance } from '../../posting_context/compliance';
import { selectComposerEffectiveCreateCapability } from '../../posting_context/create_capability';
import { materializeComposerText } from '../../posting_context/materialize';
import compose from '../../reducers/compose';
import postingContexts from '../../reducers/posting_contexts';
import relationships from '../../reducers/relationships';
import userPostingStyles from '../../reducers/user_posting_styles';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const discovery = (status, accountId = '123', { key, revision = 1 } = {}) => ({
  schema_version: 1,
  account_id: accountId,
  status,
  reason: status === 'resolved' ? null : 'no_supported_adapter',
  context: status === 'resolved' ? {
    key: key || `builtin:fedibird-group:${accountId}`,
    source: { id: 'builtin:fedibird-group', revision },
    managed: {
      hashtags: [{ name: 'squad', normalized_name: 'squad', enforcement: 'required', rule_id: 'group-tag' }],
      mentions: [{ account_id: accountId, acct: accountId === '123' ? 'localsquad' : 'othersquad', enforcement: 'required', rule_id: 'group-account-mention' }],
    },
    requirements: {
      following_accounts: [{ account_id: accountId, acct: accountId === '123' ? 'localsquad' : 'othersquad', enforcement: 'required', rule_id: 'group-follow' }],
    },
    constraints: { allowed_visibilities: ['public', 'unlisted'] },
    protocol: { activitypub: { audience: null } },
  } : null,
  discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
});

const style = fromJS({
  id: '1',
  name: 'サークル告知',
  icon: '📣',
  purpose: 'サークル向けの告知',
  revision: 2,
  target: { kind: 'group', accountId: '123', hashtag: null, label: 'localsquad' },
  defaults: { visibility: 'private' },
  managed: { hashtags: [{ name: 'fedibird', normalizedName: 'fedibird', enforcement: 'advisory' }] },
});

const storeWith = status => {
  const store = createStore(combineReducers({
    compose,
    posting_contexts: postingContexts,
    relationships,
    userPostingStyles,
  }), applyMiddleware(thunk));

  store.dispatch({
    type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
    styles: [style],
  });
  store.dispatch({
    type: POSTING_CONTEXT_FETCH_SUCCESS,
    accountId: '123',
    data: discovery(status),
    receivedAt: Date.now(),
  });
  store.dispatch({
    type: 'RELATIONSHIPS_FETCH_SUCCESS',
    relationships: [{ id: '123', following: true, requested: false }],
  });

  return store;
};

describe('commitUserPostingStyle group destination', () => {
  it('keeps the style visibility when the group only allows public or unlisted', async () => {
    const store = storeWith('resolved');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    const state = store.getState();
    const compliance = selectComposerPostingContextCompliance(state, PRIMARY_COMPOSER_ID);

    expect(state.getIn(['compose', 'privacy'])).toEqual('private');
    expect(state.getIn(['compose', 'text'])).toEqual('');
    expect(state.getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(materializeComposerText(state.get('compose'))).toEqual('@localsquad\n\n#squad #fedibird');
    expect(compliance.valid).toBe(false);
    expect(compliance.visibility.valid).toBe(false);
    expect(compliance.visibility.allowed).toEqual(['public', 'unlisted']);
  });

  it('does not treat an unsupported group as postable', async () => {
    const store = storeWith('unsupported');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    const state = store.getState();

    expect(state.getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('failed');
    expect(state.getIn(['compose', 'userPostingStyle', 'destinationFailure'])).toEqual('unsupported');
    expect(state.getIn(['compose', 'userPostingStyle', 'status'])).toEqual('failed');
    expect(state.getIn(['compose', 'context', 'protocol', 'activityPub', 'audience'])).toBeNull();
    expect(selectComposerPostingContextCompliance(state, PRIMARY_COMPOSER_ID).valid).toBe(false);
    expect(materializeComposerText(state.get('compose'))).toEqual('#fedibird');
  });
});

describe('slow group discovery', () => {
  it('waits for the in-flight result instead of failing after two seconds', async () => {
    let resolveGet;
    const get = jest.fn(() => new Promise(resolve => {
      resolveGet = resolve;
    }));
    api.mockReturnValue({ get });

    const store = createStore(combineReducers({
      compose,
      posting_contexts: postingContexts,
      relationships,
      userPostingStyles,
    }), applyMiddleware(thunk));

    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [style],
    });

    jest.useFakeTimers();
    const pending = store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    await Promise.resolve();
    jest.advanceTimersByTime(2500);
    await Promise.resolve();

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('pending');
    expect(get).toHaveBeenCalledTimes(1);

    resolveGet({ data: discovery('resolved') });
    await pending;
    jest.useRealTimers();

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(materializeComposerText(store.getState().get('compose'))).toEqual('@localsquad\n\n#squad #fedibird');
  });

  it('does not apply a group result after the style has changed', async () => {
    let resolveGet;
    const get = jest.fn(() => new Promise(resolve => {
      resolveGet = resolve;
    }));
    api.mockReturnValue({ get });

    const store = createStore(combineReducers({
      compose,
      posting_contexts: postingContexts,
      relationships,
      userPostingStyles,
    }), applyMiddleware(thunk));
    const reading = style.set('id', '2').setIn(['target', 'kind'], 'hashtag').setIn(['target', 'hashtag'], 'books').setIn(['target', 'accountId'], null);

    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [style, reading],
    });

    const pending = store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '2'));
    resolveGet({ data: discovery('resolved') });
    await pending;

    const composer = store.getState().get('compose');

    expect(composer.getIn(['userPostingStyle', 'selectedId'])).toEqual('2');
    expect(composer.getIn(['context', 'key'])).toBeNull();
    expect(materializeComposerText(composer)).not.toContain('@localsquad');
    expect(materializeComposerText(composer)).toContain('#books');
  });
});

describe('group discovery retry', () => {
  const makeStore = () => createStore(combineReducers({
    compose,
    posting_contexts: postingContexts,
    relationships,
    userPostingStyles,
  }), applyMiddleware(thunk));

  it('retries a failed group when the same style is selected again', async () => {
    let resolveRetry;
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockImplementationOnce(() => new Promise(resolve => {
        resolveRetry = resolve;
      }));
    api.mockReturnValue({ get });

    const store = makeStore();
    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [style],
    });

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('failed');
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationFailure'])).toEqual('error');
    expect(selectComposerPostingContextCompliance(store.getState(), PRIMARY_COMPOSER_ID).destination.valid).toBe(false);
    expect(get).toHaveBeenCalledTimes(1);

    const retry = store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('pending');
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationFailure'])).toBeNull();
    expect(selectComposerPostingContextCompliance(store.getState(), PRIMARY_COMPOSER_ID).valid).toBe(false);
    expect(get).toHaveBeenCalledTimes(2);

    resolveRetry({ data: discovery('resolved') });
    await retry;
    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });

    const composer = store.getState().get('compose');

    expect(composer.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(composer.getIn(['userPostingStyle', 'destinationFailure'])).toBeNull();
    expect(materializeComposerText(composer)).toEqual('@localsquad\n\n#squad #fedibird');
  });

  it('does not apply a retried group result after the style has changed', async () => {
    let resolveRetry;
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockImplementationOnce(() => new Promise(resolve => {
        resolveRetry = resolve;
      }));
    api.mockReturnValue({ get });

    const store = makeStore();
    const reading = style.set('id', '2').setIn(['target', 'kind'], 'hashtag').setIn(['target', 'hashtag'], 'books').setIn(['target', 'accountId'], null);

    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [style, reading],
    });

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));
    const retry = store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '2'));
    resolveRetry({ data: discovery('resolved') });
    await retry;

    const composer = store.getState().get('compose');

    expect(composer.getIn(['userPostingStyle', 'selectedId'])).toEqual('2');
    expect(composer.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(materializeComposerText(composer)).not.toContain('@localsquad');
    expect(materializeComposerText(composer)).toContain('#books');
  });

  it('can recover from an unsupported destination by selecting the style again', async () => {
    let resolveRetry;
    const get = jest.fn()
      .mockResolvedValueOnce({ data: discovery('unsupported') })
      .mockImplementationOnce(() => new Promise(resolve => {
        resolveRetry = resolve;
      }));
    api.mockReturnValue({ get });

    const store = makeStore();
    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [style],
    });

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationFailure'])).toEqual('unsupported');
    expect(get).toHaveBeenCalledTimes(1);

    const retry = store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('pending');
    expect(selectComposerPostingContextCompliance(store.getState(), PRIMARY_COMPOSER_ID).destination.valid).toBe(false);
    expect(get).toHaveBeenCalledTimes(2);

    resolveRetry({ data: discovery('resolved') });
    await retry;

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(materializeComposerText(store.getState().get('compose'))).toContain('@localsquad');
  });

  it('retries discovery without reapplying the style or clearing a suppressed tag', async () => {
    let resolveRetry;
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockImplementationOnce(() => new Promise(resolve => {
        resolveRetry = resolve;
      }));
    api.mockReturnValue({ get });

    const store = makeStore();
    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [style],
    });

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));
    store.dispatch(changeCompose('Keep me'));
    store.dispatch({ type: COMPOSE_VISIBILITY_CHANGE, value: 'unlisted' });
    store.dispatch({ type: COMPOSE_LANGUAGE_CHANGE, language: 'en' });
    store.dispatch({ type: COMPOSE_UPLOAD_SUCCESS, media: { id: 'm1', type: 'image' } });
    store.dispatch({ type: COMPOSE_POLL_ADD });
    store.dispatch(toggleUserPostingStyleHashtag(PRIMARY_COMPOSER_ID, 'style', 'fedibird'));

    const before = store.getState().get('compose');
    const key = before.get('idempotencyKey');
    const retry = store.dispatch(retryUserPostingStyleDestination(PRIMARY_COMPOSER_ID));
    const pending = store.getState().get('compose');

    expect(pending.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('pending');
    expect(pending.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
    expect(pending.get('text')).toEqual('Keep me');
    expect(pending.get('privacy')).toEqual('unlisted');
    expect(pending.get('language')).toEqual('en');
    expect(pending.get('media_attachments').size).toEqual(1);
    expect(pending.get('poll')).not.toBeNull();
    expect(pending.getIn(['userPostingStyle', 'manualFields']).includes('privacy')).toBe(true);
    expect(pending.getIn(['userPostingStyle', 'manualFields']).includes('language')).toBe(true);
    expect(pending.getIn(['userPostingStyle', 'suppressions']).includes('style:fedibird')).toBe(true);
    expect(pending.get('idempotencyKey')).toEqual(key);
    expect(selectComposerPostingContextCompliance(store.getState(), PRIMARY_COMPOSER_ID).valid).toBe(false);

    resolveRetry({ data: discovery('resolved') });
    await retry;

    const done = store.getState().get('compose');

    expect(done.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(done.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
    expect(done.get('text')).toEqual('Keep me');
    expect(done.get('privacy')).toEqual('unlisted');
    expect(done.get('language')).toEqual('en');
    expect(done.get('media_attachments').size).toEqual(1);
    expect(done.get('poll')).not.toBeNull();
    expect(done.getIn(['userPostingStyle', 'suppressions']).includes('style:fedibird')).toBe(true);
    expect(materializeComposerText(done)).toEqual('@localsquad Keep me\n\n#squad');
    expect(materializeComposerText(done)).not.toContain('#fedibird');
    expect(done.get('idempotencyKey')).not.toEqual(key);
  });

  it('does not apply a dedicated retry after the style has changed', async () => {
    let resolveRetry;
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockImplementationOnce(() => new Promise(resolve => {
        resolveRetry = resolve;
      }));
    api.mockReturnValue({ get });

    const store = makeStore();
    const reading = style.set('id', '2').setIn(['target', 'kind'], 'hashtag').setIn(['target', 'hashtag'], 'books').setIn(['target', 'accountId'], null);

    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [style, reading],
    });

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));
    const retry = store.dispatch(retryUserPostingStyleDestination(PRIMARY_COMPOSER_ID));

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('pending');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '2'));
    resolveRetry({ data: discovery('resolved') });
    await retry;

    const composer = store.getState().get('compose');

    expect(composer.getIn(['userPostingStyle', 'selectedId'])).toEqual('2');
    expect(materializeComposerText(composer)).not.toContain('@localsquad');
    expect(materializeComposerText(composer)).toContain('#books');
  });
});

const replyStatus = fromJS({
  id: 's1',
  language: 'ja',
  visibility: 'public',
  spoiler_text: '',
  mentions: [],
  account: { id: '2', acct: 'bob' },
});

const quoteStatus = fromJS({
  id: 's2',
  url: 'https://example.test/s2',
  visibility: 'public',
  spoiler_text: '',
});

const publicGroupStyle = style.setIn(['defaults', 'visibility'], 'public');

const otherGroupStyle = style.set('id', '9').set('name', '別サークル').setIn(['defaults', 'visibility'], 'public').set('target', fromJS({
  kind: 'group',
  accountId: '456',
  hashtag: null,
  label: 'othersquad',
}));

const booksStyle = style.set('id', '2').set('name', '読書メモ').set('defaults', fromJS({})).set('target', fromJS({
  kind: 'hashtag',
  accountId: null,
  hashtag: 'books',
  label: '#books',
}));

const follow = (accountId) => ({
  type: 'RELATIONSHIPS_FETCH_SUCCESS',
  relationships: [{ id: accountId, following: true, requested: false }],
});

const capabilityOf = (store) => selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID);

describe('style group create capability', () => {
  const makeStore = () => createStore(combineReducers({
    compose,
    posting_contexts: postingContexts,
    relationships,
    userPostingStyles,
  }), applyMiddleware(thunk));

  const expectIdentity = (composer, accountId) => {
    expect(composer.getIn(['userPostingStyle', 'destinationAccountId'])).toEqual(accountId);
    expect(composer.get('posting_context_account_id')).toEqual(accountId);
    expect(composer.getIn(['context', 'resolvedAccountId'])).toEqual(accountId);
  };

  it('aligns the style group with discovery and allows delivery when the definition matches', async () => {
    const store = makeStore();

    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_SUCCESS', styles: [publicGroupStyle] });
    store.dispatch({
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '123',
      data: discovery('resolved'),
      receivedAt: Date.now(),
    });
    store.dispatch(follow('123'));

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    const composer = store.getState().get('compose');
    const capability = capabilityOf(store);

    expectIdentity(composer, '123');
    expect(capability.delivery).toEqual({
      status: 'supported',
      authority: 'server',
      adapter: 'fedibird_group',
    });
    expect(capability.compliance.valid).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(capability.reason).toBeNull();
  });

  it('blocks submit when the applied context no longer matches discovery', async () => {
    const store = makeStore();

    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_SUCCESS', styles: [publicGroupStyle] });
    store.dispatch({
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '123',
      data: discovery('resolved'),
      receivedAt: Date.now(),
    });
    store.dispatch(follow('123'));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    store.dispatch({
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '123',
      data: discovery('resolved', '123', { key: 'builtin:fedibird-group:123:other', revision: 2 }),
      receivedAt: Date.now(),
    });

    const composer = store.getState().get('compose');
    const capability = capabilityOf(store);

    expectIdentity(composer, '123');
    expect(composer.getIn(['context', 'key'])).toEqual('builtin:fedibird-group:123');
    expect(capability.compliance.valid).toBe(true);
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
  });

  it('replaces the previous group account id when another group style is selected', async () => {
    let resolveSecond;
    const get = jest.fn()
      .mockResolvedValueOnce({ data: discovery('resolved', '123') })
      .mockImplementationOnce(() => new Promise(resolve => {
        resolveSecond = resolve;
      }));
    api.mockReturnValue({ get });

    const store = makeStore();

    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [publicGroupStyle, otherGroupStyle],
    });
    store.dispatch(follow('123'));
    store.dispatch(follow('456'));

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));
    expectIdentity(store.getState().get('compose'), '123');

    const pending = store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '9'));
    const switching = store.getState().get('compose');

    expect(switching.getIn(['userPostingStyle', 'destinationAccountId'])).toEqual('456');
    expect(switching.get('posting_context_account_id')).toEqual('456');
    expect(switching.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(switching.get('posting_context_account_id')).not.toEqual('123');
    expect(capabilityOf(store).canAttempt).toBe(false);

    resolveSecond({ data: discovery('resolved', '456') });
    await pending;

    const composer = store.getState().get('compose');

    expectIdentity(composer, '456');
    expect(composer.getIn(['context', 'key'])).toEqual('builtin:fedibird-group:456');
    expect(materializeComposerText(composer)).toContain('@othersquad');
    expect(materializeComposerText(composer)).not.toContain('@localsquad');
    expect(capabilityOf(store).delivery.status).toEqual('supported');
    expect(capabilityOf(store).canAttempt).toBe(true);
  });

  it('clears the style group identity when returning to the usual settings', async () => {
    const store = makeStore();

    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_SUCCESS', styles: [publicGroupStyle] });
    store.dispatch({
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '123',
      data: discovery('resolved'),
      receivedAt: Date.now(),
    });
    store.dispatch(follow('123'));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, null));

    const composer = store.getState().get('compose');
    const capability = capabilityOf(store);

    expect(composer.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(composer.getIn(['userPostingStyle', 'destinationAccountId'])).toBeNull();
    expect(composer.getIn(['userPostingStyle', 'destinationSource'])).toBeNull();
    expect(composer.get('posting_context_account_id')).toBeNull();
    expect(composer.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(capability.delivery.status).toEqual('not_applicable');
    expect(capability.canAttempt).toBe(true);
    expect(capability.reason).toBeNull();
  });

  it('returns to a normal post when a group style changes to a hashtag style', async () => {
    const store = makeStore();

    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [publicGroupStyle, booksStyle],
    });
    store.dispatch({
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '123',
      data: discovery('resolved'),
      receivedAt: Date.now(),
    });
    store.dispatch(follow('123'));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '2'));

    const composer = store.getState().get('compose');
    const capability = capabilityOf(store);

    expect(composer.getIn(['userPostingStyle', 'destinationAccountId'])).toBeNull();
    expect(composer.get('posting_context_account_id')).toBeNull();
    expect(composer.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(materializeComposerText(composer)).toContain('#books');
    expect(materializeComposerText(composer)).not.toContain('@localsquad');
    expect(capability.delivery.status).toEqual('not_applicable');
    expect(capability.canAttempt).toBe(true);
    expect(capability.reason).toBeNull();
  });

  it('parks the group identity for a reply or quote and restores it afterwards', async () => {
    const store = makeStore();

    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_SUCCESS', styles: [publicGroupStyle] });
    store.dispatch({
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId: '123',
      data: discovery('resolved'),
      receivedAt: Date.now(),
    });
    store.dispatch(follow('123'));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    store.dispatch({ type: COMPOSE_REPLY, status: replyStatus });

    const reply = store.getState().get('compose');
    const duringReply = capabilityOf(store);

    expect(reply.get('in_reply_to')).toEqual('s1');
    expect(reply.get('posting_context_account_id')).toBeNull();
    expect(reply.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(reply.getIn(['userPostingStyle', 'parkedPostingContextAccountId'])).toEqual('123');
    expect(reply.getIn(['userPostingStyle', 'parkedContext', 'resolvedAccountId'])).toEqual('123');
    expect(duringReply.delivery.status).toEqual('not_applicable');
    expect(duringReply.reason).not.toEqual('target_mismatch');

    store.dispatch({ type: COMPOSE_REPLY_CANCEL });

    const restored = store.getState().get('compose');

    expect(restored.get('in_reply_to')).toBeNull();
    expectIdentity(restored, '123');
    expect(capabilityOf(store).delivery.status).toEqual('supported');
    expect(capabilityOf(store).canAttempt).toBe(true);

    store.dispatch({ type: COMPOSE_QUOTE, status: quoteStatus });

    const quote = store.getState().get('compose');

    expect(quote.get('quote_from')).toEqual('s2');
    expect(quote.get('posting_context_account_id')).toBeNull();
    expect(quote.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(capabilityOf(store).delivery.status).toEqual('not_applicable');

    store.dispatch({ type: COMPOSE_QUOTE_CANCEL });

    expectIdentity(store.getState().get('compose'), '123');
    expect(capabilityOf(store).delivery.status).toEqual('supported');
    expect(capabilityOf(store).canAttempt).toBe(true);
  });

  it('re-resolves a group that was still loading when a reply started', async () => {
    let resolveGet;
    const get = jest.fn(() => new Promise(resolve => {
      resolveGet = resolve;
    }));
    api.mockReturnValue({ get });

    const store = makeStore();

    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_SUCCESS', styles: [publicGroupStyle] });
    const pending = store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    await Promise.resolve();
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('123');
    expect(capabilityOf(store).canAttempt).toBe(false);
    expect(capabilityOf(store).reason).toEqual('delivery_unresolved');

    store.dispatch({ type: COMPOSE_REPLY, status: replyStatus });
    resolveGet({ data: discovery('resolved') });
    await pending;

    expect(store.getState().getIn(['compose', 'in_reply_to'])).toEqual('s1');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toBeNull();
    expect(materializeComposerText(store.getState().get('compose'))).not.toContain('@localsquad');

    store.dispatch({ type: COMPOSE_REPLY_CANCEL });
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('needs_resolve');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('123');
    expect(capabilityOf(store).canAttempt).toBe(false);

    store.dispatch(follow('123'));
    await store.dispatch(resolveUserPostingStyleDestination(PRIMARY_COMPOSER_ID));

    expectIdentity(store.getState().get('compose'), '123');
    expect(capabilityOf(store).delivery.status).toEqual('supported');
    expect(capabilityOf(store).canAttempt).toBe(true);
  });

  it('blocks submit while discovery is retrying and after it fails', async () => {
    let resolveRetry;
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce({ data: discovery('unsupported') })
      .mockImplementationOnce(() => new Promise(resolve => {
        resolveRetry = resolve;
      }));
    api.mockReturnValue({ get });

    const store = makeStore();

    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_SUCCESS', styles: [publicGroupStyle] });
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    const failed = capabilityOf(store);

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('failed');
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('123');
    expect(store.getState().getIn(['compose', 'context', 'resolvedAccountId'])).toBeNull();
    expect(failed.canAttempt).toBe(false);
    expect(failed.reason).toEqual('delivery_unresolved');

    await store.dispatch(retryUserPostingStyleDestination(PRIMARY_COMPOSER_ID));

    const unsupported = capabilityOf(store);

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationFailure'])).toEqual('unsupported');
    expect(unsupported.canAttempt).toBe(false);
    expect(unsupported.reason).toEqual('delivery_unsupported');

    const retry = store.dispatch(retryUserPostingStyleDestination(PRIMARY_COMPOSER_ID));
    const pending = capabilityOf(store);

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('pending');
    expect(pending.canAttempt).toBe(false);
    expect(['delivery_unresolved', 'delivery_unsupported']).toContain(pending.reason);

    resolveRetry({ data: discovery('resolved') });
    await retry;
    store.dispatch(follow('123'));

    expectIdentity(store.getState().get('compose'), '123');
    expect(capabilityOf(store).delivery.status).toEqual('supported');
    expect(capabilityOf(store).canAttempt).toBe(true);
  });
});

describe('fetch failure stays usable', () => {
  it('records a failed catalog without a composer style', () => {
    const store = createStore(combineReducers({
      compose,
      userPostingStyles,
    }));

    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_FAIL' });

    expect(store.getState().getIn(['userPostingStyles', 'status'])).toEqual('failed');
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('');
    expect(ImmutableMap.isMap(store.getState().get('compose'))).toBe(true);
  });

  it('loads the catalog again after a failure when retry is requested', async () => {
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce({
        data: [{
          id: '4',
          name: '読書メモ',
          target: { kind: 'none' },
          defaults: {},
          managed: { hashtags: [] },
        }],
      });
    api.mockReturnValue({ get });

    const store = createStore(combineReducers({
      compose,
      userPostingStyles,
    }), applyMiddleware(thunk));

    await store.dispatch(fetchUserPostingStyles());

    expect(store.getState().getIn(['userPostingStyles', 'status'])).toEqual('failed');

    await store.dispatch(fetchUserPostingStyles());

    expect(get).toHaveBeenCalledTimes(1);
    expect(store.getState().getIn(['userPostingStyles', 'status'])).toEqual('failed');

    await store.dispatch(fetchUserPostingStyles({ force: true }));

    expect(get).toHaveBeenCalledTimes(2);
    expect(store.getState().getIn(['userPostingStyles', 'status'])).toEqual('ready');
    expect(store.getState().getIn(['userPostingStyles', 'styles', 0, 'name'])).toEqual('読書メモ');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('');
  });
});
