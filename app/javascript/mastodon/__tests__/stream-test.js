import { Map as ImmutableMap } from 'immutable';

jest.mock('@gamestdio/websocket', () => {
  const clients = [];

  function WebSocketClient(url, protocols) {
    this.url = url;
    this.protocols = protocols;
    this.readyState = 0;
    this.sent = [];
    this.listeners = {};
    this.closed = false;
    clients.push(this);
  }

  WebSocketClient.CONNECTING = 0;
  WebSocketClient.OPEN = 1;
  WebSocketClient.CLOSING = 2;
  WebSocketClient.CLOSED = 3;
  WebSocketClient.clients = clients;

  WebSocketClient.prototype.send = function send(data) {
    this.sent.push(JSON.parse(data));
  };

  WebSocketClient.prototype.close = function close() {
    this.closed = true;
    this.readyState = WebSocketClient.CLOSED;
  };

  const listener = (name) => {
    Object.defineProperty(WebSocketClient.prototype, name, {
      configurable: true,
      enumerable: true,
      get() {
        return this.listeners[name];
      },
      set(fn) {
        this.listeners[name] = fn;
      },
    });
  };

  ['onopen', 'onmessage', 'onclose', 'onreconnect'].forEach(listener);

  return {
    __esModule: true,
    default: WebSocketClient,
  };
});

import { KNOWN_EVENT_TYPES, subscriptionMatchesStream } from '../stream';

const preferencesPayload = JSON.stringify({
  version: 1,
  revision: '12',
  changed_keys: ['user.default_language'],
});

const stateFor = (baseUrl) => ImmutableMap({
  meta: ImmutableMap({
    streaming_api_base_url: baseUrl,
    access_token: 'token-1',
  }),
});

const dispatchWith = (baseUrl) => {
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => stateFor(baseUrl));
    }

    return action;
  };

  return dispatch;
};

describe('shared websocket delivery', () => {
  it('keeps tagged group feeds from receiving each other', () => {
    const plain = ['group', '9'];
    const news = ['group', '9', 'news'];
    const sports = ['group', '9', 'sports'];
    const otherGroup = ['group', '8', 'news'];
    const mediaNews = ['group:media', '9', 'news'];

    expect(subscriptionMatchesStream('group', { id: '9' }, plain)).toBe(true);
    expect(subscriptionMatchesStream('group', { id: '9' }, news)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'news' }, news)).toBe(true);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'news' }, sports)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'news' }, plain)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'sports' }, sports)).toBe(true);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'sports' }, news)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '8', tagged: 'news' }, news)).toBe(false);
    expect(subscriptionMatchesStream('group', { id: '8', tagged: 'news' }, otherGroup)).toBe(true);
    expect(subscriptionMatchesStream('group', { id: '9', tagged: 'news' }, mediaNews)).toBe(false);
    expect(subscriptionMatchesStream('group:media', { id: '9', tagged: 'news' }, mediaNews)).toBe(true);
  });

  it('matches the preferences channel on its own', () => {
    expect(subscriptionMatchesStream('user:preferences', {}, ['user:preferences'])).toBe(true);
    expect(subscriptionMatchesStream('user', {}, ['user:preferences'])).toBe(false);
    expect(subscriptionMatchesStream('user:preferences', {}, ['user'])).toBe(false);
  });
});

describe('preferences_changed delivery', () => {
  beforeEach(() => {
    jest.resetModules();
    const WebSocketClient = require('@gamestdio/websocket').default;

    WebSocketClient.clients.length = 0;
  });

  const loadStream = () => require('../stream');

  it('lists preferences_changed for EventSource and delivers the payload string', () => {
    const instances = [];

    function EventSource(url) {
      this.url = url;
      this.listeners = {};
      this.closed = false;
      instances.push(this);
    }

    EventSource.prototype.addEventListener = function addEventListener(type, handler) {
      this.listeners[type] = handler;
    };

    EventSource.prototype.close = function close() {
      this.closed = true;
    };

    global.EventSource = EventSource;

    const { KNOWN_EVENT_TYPES: eventTypes, connectStream: connect } = loadStream();
    const received = [];
    const dispatch = dispatchWith('http://example.test');

    expect(eventTypes).toContain('preferences_changed');
    expect(KNOWN_EVENT_TYPES).toContain('preferences_changed');

    const stop = dispatch(connect('user:preferences', {}, () => ({
      onConnect() {},
      onDisconnect() {},
      onReceive(data) {
        received.push(data);
      },
    })));

    const source = instances[0];

    expect(source.url).toBe('http://example.test/api/v1/streaming/user/preferences?access_token=token-1');
    expect(source.listeners.preferences_changed).toEqual(expect.any(Function));
    expect(source.listeners.update).toEqual(expect.any(Function));

    source.onopen();
    source.listeners.preferences_changed({
      type: 'preferences_changed',
      data: preferencesPayload,
    });

    expect(received).toEqual([{
      event: 'preferences_changed',
      payload: preferencesPayload,
    }]);
    expect(typeof received[0].payload).toBe('string');
    expect(JSON.parse(received[0].payload).revision).toBe('12');

    stop();
    expect(source.closed).toBe(true);
  });

  it('delivers a WebSocket preferences_changed frame without closing the user stream', () => {
    const { connectStream: connect } = loadStream();
    const WebSocketClient = require('@gamestdio/websocket').default;
    const userReceived = [];
    const preferencesReceived = [];
    const userConnections = [];
    const preferenceConnections = [];
    const dispatch = dispatchWith('ws://example.test');

    const stopUser = dispatch(connect('user', {}, () => ({
      onConnect() {
        userConnections.push('connect');
      },
      onDisconnect() {
        userConnections.push('disconnect');
      },
      onReceive(data) {
        userReceived.push(data);
      },
    })));
    const stopPreferences = dispatch(connect('user:preferences', {}, () => ({
      onConnect() {
        preferenceConnections.push('connect');
      },
      onDisconnect() {
        preferenceConnections.push('disconnect');
      },
      onReceive(data) {
        preferencesReceived.push(data);
      },
    })));

    expect(WebSocketClient.clients).toHaveLength(1);

    const client = WebSocketClient.clients[0];

    expect(client.url).toBe('ws://example.test/api/v1/streaming/?');
    expect(client.protocols).toBe('token-1');

    client.readyState = WebSocketClient.OPEN;
    client.onopen();

    expect(client.sent).toEqual([
      { type: 'subscribe', stream: 'user' },
      { type: 'subscribe', stream: 'user:preferences' },
    ]);
    expect(userConnections).toEqual(['connect']);
    expect(preferenceConnections).toEqual(['connect']);

    client.onmessage({
      data: JSON.stringify({
        stream: ['user:preferences'],
        event: 'preferences_changed',
        payload: preferencesPayload,
      }),
    });
    client.onmessage({
      data: JSON.stringify({
        stream: ['user'],
        event: 'update',
        payload: '{"id":"1"}',
      }),
    });

    expect(preferencesReceived).toEqual([{
      stream: ['user:preferences'],
      event: 'preferences_changed',
      payload: preferencesPayload,
    }]);
    expect(userReceived).toEqual([{
      stream: ['user'],
      event: 'update',
      payload: '{"id":"1"}',
    }]);
    expect(preferencesReceived[0].payload).toBe(preferencesPayload);
    expect(typeof preferencesReceived[0].payload).toBe('string');

    stopPreferences();

    expect(client.closed).toBe(false);
    expect(client.sent).toContainEqual({ type: 'unsubscribe', stream: 'user:preferences' });
    expect(client.sent).not.toContainEqual({ type: 'unsubscribe', stream: 'user' });
    expect(preferenceConnections).toEqual(['connect', 'disconnect']);
    expect(userConnections).toEqual(['connect']);

    client.onmessage({
      data: JSON.stringify({
        stream: ['user'],
        event: 'notification',
        payload: '{}',
      }),
    });
    client.onmessage({
      data: JSON.stringify({
        stream: ['user:preferences'],
        event: 'preferences_changed',
        payload: preferencesPayload,
      }),
    });

    expect(userReceived).toHaveLength(2);
    expect(preferencesReceived).toHaveLength(1);

    client.onclose({ code: 1006 });
    client.onopen();

    expect(userConnections).toEqual(['connect', 'disconnect', 'connect']);
    expect(stopUser).toEqual(expect.any(Function));
    expect(client.sent.filter(frame => frame.stream === 'user' && frame.type === 'subscribe')).toHaveLength(2);
  });
});
