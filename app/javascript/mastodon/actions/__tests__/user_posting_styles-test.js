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
import { COMPOSE_LANGUAGE_CHANGE, COMPOSE_POLL_ADD, COMPOSE_UPLOAD_SUCCESS, COMPOSE_VISIBILITY_CHANGE, changeCompose } from '../compose';
import { commitUserPostingStyle, fetchUserPostingStyles, retryUserPostingStyleDestination, toggleUserPostingStyleHashtag } from '../user_posting_styles';
import { POSTING_CONTEXT_FETCH_SUCCESS } from '../posting_contexts';
import { selectComposerPostingContextCompliance } from '../../posting_context/compliance';
import { materializeComposerText } from '../../posting_context/materialize';
import compose from '../../reducers/compose';
import postingContexts from '../../reducers/posting_contexts';
import relationships from '../../reducers/relationships';
import userPostingStyles from '../../reducers/user_posting_styles';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const discovery = status => ({
  schema_version: 1,
  account_id: '123',
  status,
  reason: status === 'resolved' ? null : 'no_supported_adapter',
  context: status === 'resolved' ? {
    key: 'builtin:fedibird-group:123',
    source: { id: 'builtin:fedibird-group', revision: 1 },
    managed: {
      hashtags: [{ name: 'squad', normalized_name: 'squad', enforcement: 'required', rule_id: 'group-tag' }],
      mentions: [{ account_id: '123', acct: 'localsquad', enforcement: 'required', rule_id: 'group-account-mention' }],
    },
    requirements: {
      following_accounts: [{ account_id: '123', acct: 'localsquad', enforcement: 'required', rule_id: 'group-follow' }],
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
