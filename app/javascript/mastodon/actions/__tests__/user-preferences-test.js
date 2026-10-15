import { act, render } from '@testing-library/react';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import React from 'react';
import { Provider } from 'react-redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

const connections = [];
const mockGet = jest.fn();

jest.mock('../../stream', () => ({
  connectStream: (...args) => mockConnectStream(...args),
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: () => ({ get: (...args) => mockGet(...args) }),
}));

const mockConnectStream = jest.fn((channelName, params, callbacks) => (dispatch, getState) => {
  const handlers = callbacks(dispatch, getState);
  const connection = { channelName, params, handlers, stopped: false };

  connections.push(connection);

  return () => {
    connection.stopped = true;
  };
});

import { COMPOSE_CHANGE, COMPOSE_LANGUAGE_CHANGE, COMPOSE_RESET, COMPOSE_VISIBILITY_CHANGE } from '../compose';
import { createComposer } from '../composer';
import compose from '../../reducers/compose';
import composers from '../../reducers/composers';
import rootReducer from '../../reducers';
import meta from '../../reducers/meta';
import settings from '../../reducers/settings';
import userPreferences from '../../reducers/user_preferences';
import userPostingStyles from '../../reducers/user_posting_styles';
import AppearancePreferences from '../../features/ui/components/appearance_preferences';
import { selectAcceptedTranslationPreferences } from '../../selectors/user_preferences';
import { applyAcceptedAppearance, reduceMotionNow, resetAppearancePreferences, subscribeReduceMotion } from '../../utils/appearance_preferences';
import {
  PREFERENCES_PATH,
  PREFERENCES_STREAM,
  USER_PREFERENCES_EVENT,
  USER_PREFERENCES_FETCH_FAIL,
  USER_PREFERENCES_FETCH_REQUEST,
  USER_PREFERENCES_FETCH_SUCCESS,
  WEB_UI_SESSION_SCOPES,
  connectUserPreferences,
  parsePreferencesChangedPayload,
  preferencesReadScopeGranted,
  publishAcceptedPreferenceDocument,
} from '../user_preferences';

const reducer = combineReducers({
  user_preferences: userPreferences,
  settings,
  compose,
  composers,
  meta,
  userPostingStyles,
});

const languageEntry = {
  key: 'user.default_language',
  state: 'invalid',
  configured: null,
  effective: null,
  public_value: 'not-a-language',
  public_valid: false,
  validation_errors: [{ field: 'configured', expected: ['string'], actual: 'nil' }],
};

const documentA = {
  version: 1,
  preferences: {
    'user.default_language': languageEntry,
    'user.default_privacy': {
      key: 'user.default_privacy',
      state: 'set',
      configured: 'private',
      effective: 'private',
      public_value: 'private',
      public_valid: true,
      validation_errors: [],
    },
  },
};

const documentB = {
  version: 1,
  preferences: {
    'user.default_language': {
      key: 'user.default_language',
      state: 'set',
      configured: 'en',
      effective: 'en',
      public_value: 'en',
      public_valid: true,
      validation_errors: [],
    },
    'user.default_privacy': {
      key: 'user.default_privacy',
      state: 'set',
      configured: 'public',
      effective: 'public',
      public_value: 'public',
      public_valid: true,
      validation_errors: [],
    },
  },
};

const documentC = {
  version: 1,
  preferences: {
    'user.default_language': {
      key: 'user.default_language',
      state: 'set',
      configured: 'fr',
      effective: 'fr',
      public_value: 'fr',
      public_valid: true,
      validation_errors: [],
    },
  },
};

const payload = JSON.stringify({
  version: 1,
  revision: '12',
  changed_keys: ['user.default_language'],
});

const bigintPayload = JSON.stringify({
  version: 1,
  revision: '9223372036854775807',
  changed_keys: ['user.default_privacy'],
});

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });

  return { promise, resolve, reject };
};

const flush = () => new Promise(resolve => setImmediate(resolve));

const buildStore = () => {
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.setIn(['meta', 'access_token'], 'web-ui-token');
  state = state.setIn(['meta', 'streaming_api_base_url'], 'ws://example.test');

  return createStore(reducer, state, applyMiddleware(thunk));
};

const slice = store => store.getState().get('user_preferences');

describe('user preferences stream', () => {
  beforeEach(() => {
    connections.length = 0;
    mockGet.mockReset();
  });

  const open = (store, scopes) => {
    const stop = store.dispatch(connectUserPreferences(scopes));
    const connection = connections[connections.length - 1];

    connection.handlers.onConnect();

    return { stop, handlers: connection.handlers };
  };

  const hangGets = () => {
    const pending = [];

    mockGet.mockImplementation(() => {
      const item = deferred();

      pending.push(item);

      return item.promise;
    });

    return pending;
  };

  it('checks the WebUI session token for an exact read scope', () => {
    expect(WEB_UI_SESSION_SCOPES).toEqual(['read', 'write', 'follow']);
    expect(preferencesReadScopeGranted(WEB_UI_SESSION_SCOPES)).toBe(true);
    expect(preferencesReadScopeGranted(['read'])).toBe(true);
    expect(preferencesReadScopeGranted(['read:preferences'])).toBe(true);
    expect(preferencesReadScopeGranted(['write'])).toBe(false);
    expect(preferencesReadScopeGranted(['write:preferences'])).toBe(false);
    expect(preferencesReadScopeGranted(['read:statuses'])).toBe(false);
    expect(preferencesReadScopeGranted(['read:notifications'])).toBe(false);
    expect(preferencesReadScopeGranted(['read:preferences:extra'])).toBe(false);
    expect(preferencesReadScopeGranted(null)).toBe(false);

    const allowed = buildStore();

    allowed.dispatch(connectUserPreferences(['read:preferences']));

    expect(connections).toHaveLength(1);
    expect(connections[0].channelName).toBe(PREFERENCES_STREAM);
  });

  it('fetches on the first connect and keeps the document fields intact', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    expect(connections[0].channelName).toBe(PREFERENCES_STREAM);
    expect(connections[0].params).toEqual({});
    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith(PREFERENCES_PATH);
    expect(slice(store).get('connected')).toBe(true);
    expect(slice(store).get('loading')).toBe(true);

    pending[0].resolve({ data: documentA });
    await flush();

    const stored = slice(store).get('document');

    expect(stored.version).toBe(1);
    expect(stored.preferences).toBe(documentA.preferences);
    expect(stored.preferences['user.default_language'].configured).toBe(null);
    expect(stored.preferences['user.default_language'].public_valid).toBe(false);
    expect(stored.preferences['user.default_language'].validation_errors).toEqual(languageEntry.validation_errors);
    expect(slice(store).get('loading')).toBe(false);
    expect(slice(store).get('error')).toBe(null);
    expect(slice(store).get('lastEventRevision')).toBe(null);

    handlers.onDisconnect();

    expect(slice(store).get('connected')).toBe(false);
    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
  });

  it('fetches again when the stream reconnects', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    pending[0].resolve({ data: documentA });
    await flush();

    handlers.onDisconnect();
    handlers.onConnect();

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(slice(store).get('document').preferences).toBe(documentA.preferences);

    pending[1].resolve({ data: documentB });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentB.preferences);
    expect(slice(store).get('lastEventRevision')).toBe(null);
  });

  it('passes the same preferences_changed payload from SSE and WebSocket into one fetch', async () => {
    mockGet.mockResolvedValue({ data: documentA });
    const store = buildStore();
    const { handlers } = open(store);

    await flush();
    mockGet.mockClear();

    handlers.onReceive({
      event: 'preferences_changed',
      payload,
    });
    await flush();

    handlers.onReceive({
      stream: ['user:preferences'],
      event: 'preferences_changed',
      payload,
    });
    await flush();

    expect(parsePreferencesChangedPayload(payload)).toEqual({ revision: '12' });
    expect(slice(store).get('lastEventRevision')).toBe('12');
    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
  });

  it('coalesces a burst of events into one follow-up fetch', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    for (let index = 0; index < 5; index += 1) {
      handlers.onReceive({ event: 'preferences_changed', payload });
    }

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(slice(store).get('refetchNeeded')).toBe(true);
    expect(slice(store).get('lastEventRevision')).toBe('12');

    pending[0].resolve({ data: documentA });
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
    expect(slice(store).get('refetchNeeded')).toBe(false);

    pending[1].resolve({ data: documentB });
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(slice(store).get('document').preferences).toBe(documentB.preferences);
  });

  it('does not let a reconnect fetch race an event fetch', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    handlers.onDisconnect();
    handlers.onConnect();
    handlers.onReceive({ event: 'preferences_changed', payload });

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(slice(store).get('refetchNeeded')).toBe(true);

    pending[0].resolve({ data: documentA });
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(2);

    pending[1].resolve({ data: documentB });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentB.preferences);
  });

  it('runs one follow-up fetch when an event arrives during a failed fetch', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    handlers.onReceive({ event: 'preferences_changed', payload });
    expect(mockGet).toHaveBeenCalledTimes(1);

    pending[0].reject({ request: {} });
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(slice(store).get('document')).toBe(null);
    expect(slice(store).get('error')).toEqual({ kind: 'network', status: null });

    pending[1].resolve({ data: documentA });
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
    expect(slice(store).get('lastEventRevision')).toBe('12');
  });

  it('ignores an older fetch result after a newer one is accepted', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    pending[0].resolve({ data: documentA });
    await flush();

    handlers.onReceive({ event: 'preferences_changed', payload });
    expect(mockGet).toHaveBeenCalledTimes(2);

    store.dispatch({
      type: USER_PREFERENCES_FETCH_SUCCESS,
      serial: 1,
      document: {
        version: 1,
        preferences: { stale: true },
      },
      skipLoading: true,
      skipAlert: true,
    });

    expect(slice(store).get('document').preferences).toBe(documentA.preferences);

    pending[1].resolve({ data: documentB });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentB.preferences);
    expect(slice(store).get('acceptedSerial')).toBe(2);

    store.dispatch({
      type: USER_PREFERENCES_FETCH_SUCCESS,
      serial: 1,
      document: documentA,
      skipLoading: true,
      skipAlert: true,
    });

    expect(slice(store).get('document').preferences).toBe(documentB.preferences);
  });

  it('accepts a new fetch after remount when acceptedSerial is already 2', async () => {
    const pending = hangGets();
    const store = buildStore();
    const first = open(store);

    pending[0].resolve({ data: documentA });
    await flush();
    first.handlers.onReceive({ event: 'preferences_changed', payload });
    pending[1].resolve({ data: documentB });
    await flush();

    expect(slice(store).get('acceptedSerial')).toBe(2);
    expect(slice(store).get('issuedSerial')).toBe(2);
    expect(slice(store).get('document').preferences).toBe(documentB.preferences);

    first.stop();

    expect(slice(store).get('acceptedSerial')).toBe(2);
    expect(slice(store).get('issuedSerial')).toBe(2);
    expect(slice(store).get('connected')).toBe(false);

    open(store);

    expect(mockGet).toHaveBeenCalledTimes(3);
    expect(slice(store).get('issuedSerial')).toBe(3);

    pending[2].resolve({ data: documentC });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentC.preferences);
    expect(slice(store).get('acceptedSerial')).toBe(3);
    expect(slice(store).get('loading')).toBe(false);
    expect(slice(store).get('error')).toBe(null);
  });

  it('keeps the remounted document when the previous fetch resolves later', async () => {
    const pending = hangGets();
    const store = buildStore();
    const first = open(store);

    expect(slice(store).get('issuedSerial')).toBe(1);
    first.stop();

    open(store);
    expect(slice(store).get('issuedSerial')).toBe(2);

    pending[1].resolve({ data: documentC });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentC.preferences);
    expect(slice(store).get('acceptedSerial')).toBe(2);

    pending[0].resolve({ data: documentA });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentC.preferences);
    expect(slice(store).get('acceptedSerial')).toBe(2);
    expect(slice(store).get('error')).toBe(null);
    expect(slice(store).get('authorizationBlocked')).toBe(false);

    store.dispatch({
      type: USER_PREFERENCES_FETCH_SUCCESS,
      serial: 1,
      document: documentA,
      skipLoading: true,
      skipAlert: true,
    });

    expect(slice(store).get('document').preferences).toBe(documentC.preferences);
  });

  it('ignores a late failure from the previous subscription', async () => {
    const pending = hangGets();
    const store = buildStore();
    const first = open(store);

    first.stop();
    open(store);

    pending[1].reject({ request: {} });
    await flush();

    expect(slice(store).get('document')).toBe(null);
    expect(slice(store).get('error')).toEqual({ kind: 'network', status: null });
    expect(slice(store).get('authorizationBlocked')).toBe(false);
    expect(slice(store).get('acceptedSerial')).toBe(2);

    pending[0].reject({ response: { status: 401 } });
    await flush();

    expect(slice(store).get('error')).toEqual({ kind: 'network', status: null });
    expect(slice(store).get('authorizationBlocked')).toBe(false);
    expect(slice(store).get('acceptedSerial')).toBe(2);
    expect(slice(store).get('issuedSerial')).toBe(2);

    store.dispatch({
      type: USER_PREFERENCES_FETCH_FAIL,
      serial: 1,
      error: { kind: 'authorization', status: 401 },
      skipLoading: true,
      skipAlert: true,
    });

    expect(slice(store).get('error')).toEqual({ kind: 'network', status: null });
    expect(slice(store).get('authorizationBlocked')).toBe(false);
  });

  it('keeps the highest decimal revision string and still fetches for an older event', async () => {
    mockGet.mockResolvedValue({ data: documentA });
    const store = buildStore();
    const { handlers } = open(store);
    const revisionEvent = revision => ({
      event: 'preferences_changed',
      payload: JSON.stringify({
        version: 1,
        revision,
        changed_keys: ['user.default_language'],
      }),
    });

    await flush();
    mockGet.mockClear();

    handlers.onReceive(revisionEvent('9'));
    await flush();
    expect(slice(store).get('lastEventRevision')).toBe('9');

    handlers.onReceive(revisionEvent('10'));
    await flush();
    expect(slice(store).get('lastEventRevision')).toBe('10');

    handlers.onReceive(revisionEvent('9'));
    await flush();
    expect(slice(store).get('lastEventRevision')).toBe('10');
    expect(mockGet).toHaveBeenCalledTimes(3);

    handlers.onReceive(revisionEvent('12'));
    await flush();
    handlers.onReceive(revisionEvent('12'));
    await flush();
    expect(slice(store).get('lastEventRevision')).toBe('12');
    expect(mockGet).toHaveBeenCalledTimes(5);

    handlers.onReceive(revisionEvent('9223372036854775807'));
    await flush();
    expect(slice(store).get('lastEventRevision')).toBe('9223372036854775807');
    expect(typeof slice(store).get('lastEventRevision')).toBe('string');

    handlers.onReceive(revisionEvent('9223372036854775806'));
    await flush();
    expect(slice(store).get('lastEventRevision')).toBe('9223372036854775807');
    expect(slice(store).get('lastEventRevision')).not.toBe(String(Number('9223372036854775807')));

    const callsAfterBoundary = mockGet.mock.calls.length;

    handlers.onReceive(revisionEvent('09'));
    handlers.onReceive({
      event: 'preferences_changed',
      payload: '{"version":1,"revision":9223372036854775808,"changed_keys":["user.default_language"]}',
    });
    store.dispatch({
      type: USER_PREFERENCES_EVENT,
      revision: 10,
      skipLoading: true,
      skipAlert: true,
    });
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(callsAfterBoundary);
    expect(slice(store).get('lastEventRevision')).toBe('9223372036854775807');
    expect(typeof slice(store).get('lastEventRevision')).toBe('string');
    expect(parsePreferencesChangedPayload(JSON.stringify({
      version: 1,
      revision: '09',
      changed_keys: ['user.default_language'],
    }))).toBe(null);
    expect(parsePreferencesChangedPayload(JSON.stringify({
      version: 1,
      revision: '0',
      changed_keys: ['user.default_language'],
    }))).toEqual({ revision: '0' });
  });

  it('keeps the saved document when a later fetch fails', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    pending[0].resolve({ data: documentA });
    await flush();

    handlers.onReceive({ event: 'preferences_changed', payload });
    pending[1].reject({ request: {} });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
    expect(slice(store).get('error')).toEqual({ kind: 'network', status: null });
    expect(slice(store).get('authorizationBlocked')).toBe(false);

    handlers.onReceive({
      event: 'preferences_changed',
      payload: JSON.stringify({ version: 1, revision: '13', changed_keys: ['user.default_sensitive'] }),
    });
    pending[2].reject({ response: { status: 500 } });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
    expect(slice(store).get('error')).toEqual({ kind: 'network', status: 500 });
    expect(slice(store).get('lastEventRevision')).toBe('13');
  });

  it('stops automatic fetches after an authorization error', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    pending[0].resolve({ data: documentA });
    await flush();

    handlers.onReceive({ event: 'preferences_changed', payload });
    handlers.onReceive({
      event: 'preferences_changed',
      payload: JSON.stringify({ version: 1, revision: '13', changed_keys: ['user.default_language'] }),
    });
    pending[1].reject({ response: { status: 401 } });
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
    expect(slice(store).get('authorizationBlocked')).toBe(true);
    expect(slice(store).get('error')).toEqual({ kind: 'authorization', status: 401 });

    handlers.onReceive({
      event: 'preferences_changed',
      payload: JSON.stringify({ version: 1, revision: '14', changed_keys: ['user.default_language'] }),
    });
    handlers.onDisconnect();
    handlers.onConnect();
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
  });

  it('treats 403 as authorization and a malformed document as a failed fetch', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { handlers } = open(store);

    pending[0].resolve({ data: documentA });
    await flush();

    handlers.onReceive({ event: 'preferences_changed', payload });
    pending[1].resolve({ data: { version: 1, preferences: null } });
    await flush();

    expect(slice(store).get('document').preferences).toBe(documentA.preferences);
    expect(slice(store).get('error')).toEqual({ kind: 'invalid_document', status: null });
    expect(slice(store).get('authorizationBlocked')).toBe(false);

    handlers.onReceive({
      event: 'preferences_changed',
      payload: JSON.stringify({ version: 1, revision: '13', changed_keys: [] }),
    });
    pending[2].reject({ response: { status: 403 } });
    await flush();

    expect(slice(store).get('error')).toEqual({ kind: 'authorization', status: 403 });
    expect(slice(store).get('document').preferences).toBe(documentA.preferences);

    handlers.onConnect();
    expect(mockGet).toHaveBeenCalledTimes(3);
  });

  it('rejects an invalid payload without fetching or coercing the revision', async () => {
    mockGet.mockResolvedValue({ data: documentA });
    const store = buildStore();
    const { handlers } = open(store);

    await flush();
    handlers.onReceive({ event: 'preferences_changed', payload: bigintPayload });
    await flush();

    expect(slice(store).get('lastEventRevision')).toBe('9223372036854775807');
    expect(typeof slice(store).get('lastEventRevision')).toBe('string');
    expect(slice(store).get('lastEventRevision')).not.toBe(String(Number('9223372036854775807')));

    const callsAfterBigint = mockGet.mock.calls.length;
    const rejected = [
      '{',
      JSON.stringify({ version: 2, revision: '12', changed_keys: ['user.default_language'] }),
      JSON.stringify({ version: 1, revision: 12, changed_keys: ['user.default_language'] }),
      '{"version":1,"revision":9223372036854775807,"changed_keys":["user.default_language"]}',
      JSON.stringify({ version: 1, revision: '12', changed_keys: 'user.default_language' }),
      JSON.stringify({ version: 1, revision: '12', changed_keys: [12] }),
      JSON.stringify({ version: 1, revision: ' 12', changed_keys: ['user.default_language'] }),
      JSON.stringify({ revision: '12', changed_keys: ['user.default_language'] }),
      { version: 1, revision: '12', changed_keys: ['user.default_language'] },
    ];

    rejected.forEach(body => {
      handlers.onReceive({
        event: 'preferences_changed',
        payload: body,
      });
    });
    handlers.onReceive({ event: 'update', payload: '{}' });
    await flush();

    expect(mockGet).toHaveBeenCalledTimes(callsAfterBigint);
    expect(slice(store).get('lastEventRevision')).toBe('9223372036854775807');
    expect(parsePreferencesChangedPayload(
      '{"version":1,"revision":9223372036854775807,"changed_keys":["user.default_language"]}',
    )).toBe(null);
  });

  it('does not apply a response after unsubscribe', async () => {
    const pending = hangGets();
    const store = buildStore();
    const { stop, handlers } = open(store);

    expect(slice(store).get('loading')).toBe(true);

    stop();
    handlers.onReceive({ event: 'preferences_changed', payload });
    handlers.onConnect();

    expect(connections[0].stopped).toBe(true);
    expect(slice(store).get('loading')).toBe(false);
    expect(slice(store).get('connected')).toBe(false);
    expect(slice(store).get('document')).toBe(null);

    pending[0].resolve({ data: documentA });
    await flush();

    expect(slice(store).get('document')).toBe(null);
    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(slice(store).get('lastEventRevision')).toBe(null);
  });

  it('subscribes only to user:preferences and does not block on a denied scope', () => {
    const store = buildStore();

    store.dispatch(connectUserPreferences(['write']));

    expect(connections).toHaveLength(0);
    expect(mockGet).not.toHaveBeenCalled();
    expect(slice(store).get('authorizationBlocked')).toBe(true);
    expect(slice(store).get('error')).toEqual({ kind: 'authorization', status: null });
    expect(slice(store).get('document')).toBe(null);

    store.dispatch(connectUserPreferences(['read:preferences']));

    expect(connections).toHaveLength(0);
    expect(mockGet).not.toHaveBeenCalled();
  });

  it('does not subscribe without an access token', () => {
    let state = reducer(undefined, { type: '@@INIT' });

    state = state.setIn(['meta', 'streaming_api_base_url'], 'ws://example.test');

    const store = createStore(reducer, state, applyMiddleware(thunk));

    store.dispatch(connectUserPreferences());

    expect(connections).toHaveLength(0);
    expect(mockGet).not.toHaveBeenCalled();
    expect(slice(store).get('authorizationBlocked')).toBe(true);
    expect(store.getState().getIn(['meta', 'access_token'])).toBe(null);
  });

  it('does not change Web::Setting, meta, or an in-progress composer', async () => {
    mockGet.mockResolvedValue({ data: documentB });

    const store = buildStore();

    store.dispatch({ type: 'SETTING_CHANGE', path: ['home', 'shows', 'reblog'], value: false });
    store.dispatch({ type: COMPOSE_CHANGE, text: '下書きです' });
    store.dispatch({ type: COMPOSE_VISIBILITY_CHANGE, value: 'unlisted' });
    store.dispatch({ type: COMPOSE_LANGUAGE_CHANGE, language: 'ja' });

    const settingsBefore = store.getState().get('settings');
    const composeBefore = store.getState().get('compose');
    const metaBefore = store.getState().get('meta');
    const stylesBefore = store.getState().get('userPostingStyles');

    const { handlers } = open(store);

    await flush();
    handlers.onReceive({ event: 'preferences_changed', payload: bigintPayload });
    await flush();

    expect(store.getState().get('settings')).toEqual(settingsBefore);
    expect(store.getState().get('compose')).toEqual(composeBefore);
    expect(store.getState().get('meta')).toEqual(metaBefore);
    expect(store.getState().get('userPostingStyles')).toEqual(stylesBefore);
    expect(store.getState().getIn(['compose', 'text'])).toBe('下書きです');
    expect(store.getState().getIn(['compose', 'privacy'])).toBe('unlisted');
    expect(store.getState().getIn(['compose', 'language'])).toBe('ja');
    expect(store.getState().getIn(['compose', 'default_privacy'])).toBe('public');
    expect(store.getState().getIn(['compose', 'default_language'])).toBe(null);
    expect(store.getState().getIn(['settings', 'home', 'shows', 'reblog'])).toBe(false);
    expect(slice(store).get('document').preferences['user.default_privacy'].configured).toBe('public');
    expect(slice(store).get('document').preferences['user.default_language'].configured).toBe('en');
    expect(mockConnectStream).toHaveBeenCalledWith(PREFERENCES_STREAM, {}, expect.any(Function));
    expect(mockConnectStream.mock.calls.every(call => call[0] !== 'user')).toBe(true);
  });

  it('registers the slice on the root reducer without writing other settings state', () => {
    const before = rootReducer(undefined, { type: '@@INIT' });
    const requested = rootReducer(before, {
      type: USER_PREFERENCES_FETCH_REQUEST,
      serial: 1,
      skipLoading: true,
      skipAlert: true,
    });
    const after = rootReducer(requested, {
      type: USER_PREFERENCES_FETCH_SUCCESS,
      serial: 1,
      document: documentB,
      skipLoading: true,
      skipAlert: true,
    });

    expect(after.getIn(['user_preferences', 'document']).preferences).toBe(documentB.preferences);
    expect(after.get('settings')).toEqual(before.get('settings'));
    expect(after.get('compose')).toEqual(before.get('compose'));
    expect(after.get('composers')).toEqual(before.get('composers'));
    expect(after.get('meta')).toEqual(before.get('meta'));
    expect(after.get('userPostingStyles')).toEqual(before.get('userPostingStyles'));
  });

  const preferenceEntry = (key, publicValue, valid = true) => ({
    key,
    state: 'set',
    configured: publicValue,
    effective: publicValue,
    public_value: publicValue,
    public_valid: valid,
    validation_errors: [],
  });

  const liveDocument = (privacy, language) => ({
    version: 1,
    preferences: {
      'user.default_privacy': preferenceEntry('user.default_privacy', privacy),
      'user.default_sensitive': preferenceEntry('user.default_sensitive', true),
      'user.default_language': preferenceEntry('user.default_language', 'en'),
      'user.preferred_posting_language': preferenceEntry('user.preferred_posting_language', language),
      'user.show_translation_bar': preferenceEntry('user.show_translation_bar', 'nope', false),
      'user.translation_preferred_mode': preferenceEntry('user.translation_preferred_mode', 'both'),
      'user.new_features_policy': preferenceEntry('user.new_features_policy', 'tester'),
      'user.content_font_size': preferenceEntry('user.content_font_size', privacy === 'private' ? 15 : 18),
      'user.info_font_size': preferenceEntry('user.info_font_size', 15),
      'user.reduce_motion': preferenceEntry('user.reduce_motion', false),
    },
  });

  it('applies an accepted document and ignores a stale or failed response', async () => {
    const pending = hangGets();
    const store = buildStore();

    store.dispatch({ type: COMPOSE_CHANGE, text: '下書きです' });
    store.dispatch({ type: COMPOSE_VISIBILITY_CHANGE, value: 'unlisted' });
    store.dispatch(createComposer('composer-draft'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'portable', meta: { composerId: 'composer-draft' } });
    store.dispatch(createComposer('composer-idle'));
    let state = store.getState();
    state = state.setIn(['meta', 'content_font_size'], 15);
    state = state.setIn(['meta', 'info_font_size'], 15);
    state = state.setIn(['meta', 'reduce_motion'], false);

    const seeded = createStore(reducer, state, applyMiddleware(thunk));
    const settingsBefore = seeded.getState().get('settings');
    const metaBefore = seeded.getState().get('meta');
    const stylesBefore = seeded.getState().get('userPostingStyles');
    const first = open(seeded);

    pending[0].resolve({ data: liveDocument('private', 'ja') });
    await flush();

    expect(seeded.getState().getIn(['compose', 'text'])).toBe('下書きです');
    expect(seeded.getState().getIn(['compose', 'privacy'])).toBe('unlisted');
    expect(seeded.getState().getIn(['compose', 'default_privacy'])).toBe('private');
    expect(seeded.getState().getIn(['compose', 'default_language'])).toBe('ja');
    expect(seeded.getState().getIn(['compose', 'default_sensitive'])).toBe(true);
    expect(seeded.getState().getIn(['compose', 'sensitive'])).toBe(false);
    expect(seeded.getState().getIn(['composers', 'byId', 'composer-draft', 'text'])).toBe('portable');
    expect(seeded.getState().getIn(['composers', 'byId', 'composer-draft', 'default_language'])).toBe('ja');
    expect(seeded.getState().getIn(['composers', 'byId', 'composer-idle', 'privacy'])).toBe('private');
    expect(seeded.getState().getIn(['composers', 'byId', 'composer-idle', 'language'])).toBe('ja');
    expect(seeded.getState().getIn(['composers', 'byId', 'composer-idle', 'sensitive'])).toBe(false);
    expect(selectAcceptedTranslationPreferences(seeded.getState())).toEqual({
      visibility: 'always',
      preferredMode: 'both',
    });
    document.body.className = 'app-body theme-contrast';
    applyAcceptedAppearance(seeded.getState().getIn(['user_preferences', 'document']));
    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('15px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('15px');
    expect(document.body.classList.contains('no-reduce-motion')).toBe(true);
    expect(document.body.classList.contains('reduce-motion')).toBe(false);
    expect(document.body.classList.contains('theme-contrast')).toBe(true);
    expect(seeded.getState().getIn(['compose', 'text'])).toBe('下書きです');
    expect(seeded.getState().get('settings')).toEqual(settingsBefore);
    expect(seeded.getState().get('meta')).toEqual(metaBefore);
    expect(seeded.getState().get('userPostingStyles')).toEqual(stylesBefore);

    first.handlers.onReceive({ event: 'preferences_changed', payload });
    pending[1].resolve({ data: liveDocument('public', 'fr') });
    await flush();

    expect(seeded.getState().getIn(['compose', 'text'])).toBe('下書きです');
    expect(seeded.getState().getIn(['compose', 'privacy'])).toBe('unlisted');
    expect(seeded.getState().getIn(['compose', 'default_privacy'])).toBe('public');
    expect(seeded.getState().getIn(['compose', 'default_language'])).toBe('fr');
    applyAcceptedAppearance(seeded.getState().getIn(['user_preferences', 'document']));
    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('18px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('15px');
    expect(document.body.classList.contains('theme-contrast')).toBe(true);
    expect(seeded.getState().getIn(['compose', 'text'])).toBe('下書きです');
    expect(seeded.getState().get('meta')).toEqual(metaBefore);

    const reset = seeded.getState().get('compose');
    seeded.dispatch({ type: COMPOSE_RESET });
    expect(seeded.getState().getIn(['compose', 'text'])).toBe('');
    expect(seeded.getState().getIn(['compose', 'privacy'])).toBe('public');
    expect(seeded.getState().getIn(['compose', 'language'])).toBe('fr');
    expect(seeded.getState().getIn(['compose', 'sensitive'])).toBe(false);
    expect(reset.get('text')).toBe('下書きです');

    first.handlers.onReceive({ event: 'preferences_changed', payload: bigintPayload });
    pending[2].reject({ request: {} });
    await flush();

    expect(seeded.getState().getIn(['user_preferences', 'document']).preferences['user.default_privacy'].public_value).toBe('public');
    expect(seeded.getState().getIn(['compose', 'default_language'])).toBe('fr');
    applyAcceptedAppearance(seeded.getState().getIn(['user_preferences', 'document']));
    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('18px');
    resetAppearancePreferences();
    document.documentElement.style.removeProperty('--content-font-size');
    document.documentElement.style.removeProperty('--info-font-size');
    document.body.className = '';

    expect(seeded.dispatch(publishAcceptedPreferenceDocument(1, liveDocument('private', 'ja')))).toBe(false);
    expect(seeded.getState().getIn(['compose', 'default_language'])).toBe('fr');
  });

  it('does not let a late response from a previous subscription change composers', async () => {
    const pending = hangGets();
    const store = buildStore();
    const first = open(store);

    first.stop();
    const second = open(store);

    pending[1].resolve({ data: liveDocument('private', 'ja') });
    await flush();
    pending[0].resolve({ data: liveDocument('public', 'en') });
    await flush();

    expect(slice(store).get('acceptedSerial')).toBe(2);
    expect(store.getState().getIn(['compose', 'default_privacy'])).toBe('private');
    expect(store.getState().getIn(['compose', 'default_language'])).toBe('ja');
    expect(store.getState().getIn(['compose', 'privacy'])).toBe('private');
    expect(second).toBeTruthy();

    store.dispatch({
      type: USER_PREFERENCES_FETCH_SUCCESS,
      serial: 1,
      document: liveDocument('public', 'en'),
      skipLoading: true,
      skipAlert: true,
    });

    expect(store.getState().getIn(['compose', 'default_language'])).toBe('ja');
    expect(slice(store).get('document').preferences['user.preferred_posting_language'].public_value).toBe('ja');
  });

  it('applies only an accepted document, including after reconnect and not after unmount', async () => {
    const pending = hangGets();
    const store = buildStore();
    const notices = [];

    resetAppearancePreferences();
    const unsubscribe = subscribeReduceMotion(() => {
      notices.push(reduceMotionNow(null));
    });
    const fontDocument = (content, info, motion, options = {}) => ({
      version: 1,
      preferences: {
        'user.content_font_size': preferenceEntry('user.content_font_size', content, options.contentValid !== false),
        'user.info_font_size': preferenceEntry('user.info_font_size', info, options.infoValid !== false),
        ...(options.omitMotion ? {} : {
          'user.reduce_motion': preferenceEntry('user.reduce_motion', motion, options.motionValid !== false),
        }),
      },
    });

    document.documentElement.style.removeProperty('--content-font-size');
    document.documentElement.style.removeProperty('--info-font-size');
    document.body.className = 'theme-mastodon';

    const view = render(
      <Provider store={store}>
        <AppearancePreferences />
      </Provider>,
    );
    const first = open(store);

    pending[0].resolve({ data: fontDocument(18, 19, true, { infoValid: false, omitMotion: true }) });
    await act(async () => {
      await flush();
    });

    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('18px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('');
    expect(document.body.className).toBe('theme-mastodon');
    expect(notices).toEqual([]);

    store.dispatch({
      type: USER_PREFERENCES_FETCH_SUCCESS,
      serial: 1,
      document: fontDocument(11, 12, false),
      skipLoading: true,
      skipAlert: true,
    });

    expect(slice(store).get('document').preferences['user.content_font_size'].public_value).toBe(18);
    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('18px');
    expect(notices).toEqual([]);

    first.handlers.onDisconnect();
    first.handlers.onConnect();
    pending[1].resolve({ data: fontDocument(16, 12, false) });
    await act(async () => {
      await flush();
    });

    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('16px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('12px');
    expect(document.body.classList.contains('no-reduce-motion')).toBe(true);
    expect(document.body.classList.contains('theme-mastodon')).toBe(true);
    expect(notices).toEqual([false]);

    view.unmount();
    first.handlers.onReceive({ event: 'preferences_changed', payload });
    pending[2].resolve({ data: fontDocument(10, 20, true) });
    await flush();

    expect(slice(store).get('document').preferences['user.content_font_size'].public_value).toBe(10);
    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('16px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('12px');
    expect(document.body.classList.contains('reduce-motion')).toBe(false);
    expect(notices).toEqual([false]);

    render(
      <Provider store={store}>
        <AppearancePreferences />
      </Provider>,
    );

    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('10px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('20px');
    expect(document.body.classList.contains('reduce-motion')).toBe(true);
    expect(notices).toEqual([false, true]);

    unsubscribe();
    resetAppearancePreferences();
    document.body.className = '';
    document.documentElement.style.removeProperty('--content-font-size');
    document.documentElement.style.removeProperty('--info-font-size');
  });
});
