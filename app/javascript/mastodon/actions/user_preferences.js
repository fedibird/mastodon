import api from '../api';
import { connectStream } from '../stream';

export const USER_PREFERENCES_CONNECTED = 'USER_PREFERENCES_CONNECTED';
export const USER_PREFERENCES_DISCONNECTED = 'USER_PREFERENCES_DISCONNECTED';
export const USER_PREFERENCES_UNSUBSCRIBED = 'USER_PREFERENCES_UNSUBSCRIBED';
export const USER_PREFERENCES_EVENT = 'USER_PREFERENCES_EVENT';
export const USER_PREFERENCES_REFETCH_NEEDED = 'USER_PREFERENCES_REFETCH_NEEDED';
export const USER_PREFERENCES_FETCH_REQUEST = 'USER_PREFERENCES_FETCH_REQUEST';
export const USER_PREFERENCES_FETCH_SUCCESS = 'USER_PREFERENCES_FETCH_SUCCESS';
export const USER_PREFERENCES_FETCH_FAIL = 'USER_PREFERENCES_FETCH_FAIL';
export const USER_PREFERENCES_AUTHORIZATION_BLOCKED = 'USER_PREFERENCES_AUTHORIZATION_BLOCKED';

export const PREFERENCES_PATH = '/api/v1/fedibird/preferences';
export const PREFERENCES_STREAM = 'user:preferences';

// SessionActivation#access_token_attributes grants the signed-in WebUI token
// these scopes. Initial state meta carries the token string and not the
// scope list, so the read check uses this known grant. Exact scope names
// only: `read:statuses` does not satisfy `read`.
export const WEB_UI_SESSION_SCOPES = ['read', 'write', 'follow'];

const DECIMAL_REVISION = /^[0-9]+$/;

const quiet = action => Object.assign({ skipLoading: true, skipAlert: true }, action);

export const preferencesReadScopeGranted = (scopes) => {
  if (!Array.isArray(scopes)) {
    return false;
  }

  return scopes.indexOf('read') !== -1 || scopes.indexOf('read:preferences') !== -1;
};

// SSE and WebSocket both hand the payload through as a JSON string. A numeric
// revision has already lost integer precision inside JSON.parse, so only a
// decimal string is accepted and it is never passed through Number.
export const parsePreferencesChangedPayload = (payload) => {
  if (typeof payload !== 'string') {
    return null;
  }

  let parsed;

  try {
    parsed = JSON.parse(payload);
  } catch (error) {
    void error;
    return null;
  }

  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null;
  }

  if (parsed.version !== 1) {
    return null;
  }

  if (typeof parsed.revision !== 'string' || !DECIMAL_REVISION.test(parsed.revision)) {
    return null;
  }

  if (!Array.isArray(parsed.changed_keys) || !parsed.changed_keys.every(key => typeof key === 'string')) {
    return null;
  }

  return { revision: parsed.revision };
};

const preferenceDocument = (data) => {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return null;
  }

  if (!Object.prototype.hasOwnProperty.call(data, 'version') || !Object.prototype.hasOwnProperty.call(data, 'preferences')) {
    return null;
  }

  const preferences = data.preferences;

  if (!preferences || typeof preferences !== 'object' || Array.isArray(preferences)) {
    return null;
  }

  return {
    version: data.version,
    preferences,
  };
};

const httpStatus = (error) => (
  error && error.response && Number.isInteger(error.response.status) ? error.response.status : null
);

// GET /api/v1/fedibird/preferences returns { version, preferences } and does
// not include a revision. lastEventRevision is the latest accepted
// preferences_changed revision, not a confirmed revision of the stored
// document. Redis Pub/Sub does not replay, so a missed event is recovered
// only by fetching again when the stream connects or reconnects. One GET is
// in flight at a time; a newer connect or event queues a single follow-up
// so responses cannot overwrite each other out of order.
export function connectUserPreferences(scopes = WEB_UI_SESSION_SCOPES) {
  return (dispatch, getState) => {
    if (getState().getIn(['user_preferences', 'authorizationBlocked'])) {
      return () => {};
    }

    const token = getState().getIn(['meta', 'access_token'], '');

    if (!token || !preferencesReadScopeGranted(scopes)) {
      dispatch(quiet({
        type: USER_PREFERENCES_AUTHORIZATION_BLOCKED,
        status: null,
      }));

      return () => {};
    }

    let disposed = false;
    let blocked = false;
    let inFlight = false;
    let followUp = false;
    let serial = 0;

    const fail = (requestSerial, error) => {
      dispatch(quiet({
        type: USER_PREFERENCES_FETCH_FAIL,
        serial: requestSerial,
        error,
      }));
    };

    const fetchDocument = () => {
      if (disposed || blocked) {
        return null;
      }

      if (getState().getIn(['user_preferences', 'authorizationBlocked'])) {
        blocked = true;
        return null;
      }

      if (inFlight) {
        followUp = true;
        dispatch(quiet({ type: USER_PREFERENCES_REFETCH_NEEDED }));
        return null;
      }

      inFlight = true;
      followUp = false;
      serial += 1;
      const requestSerial = serial;

      dispatch(quiet({
        type: USER_PREFERENCES_FETCH_REQUEST,
        serial: requestSerial,
      }));

      return api(getState).get(PREFERENCES_PATH).then((response) => {
        inFlight = false;

        if (disposed || requestSerial !== serial) {
          return null;
        }

        const document = preferenceDocument(response && response.data);

        const responseStatus = response && Number.isInteger(response.status) ? response.status : null;

        if (!document) {
          fail(requestSerial, { kind: 'invalid_document', status: responseStatus });
        } else {
          dispatch(quiet({
            type: USER_PREFERENCES_FETCH_SUCCESS,
            serial: requestSerial,
            document,
          }));
        }

        if (!disposed && followUp && !blocked) {
          followUp = false;
          fetchDocument();
        }

        return null;
      }).catch((error) => {
        inFlight = false;

        if (disposed || requestSerial !== serial) {
          return null;
        }

        const status = httpStatus(error);

        if (status === 401 || status === 403) {
          blocked = true;
          followUp = false;
          fail(requestSerial, { kind: 'authorization', status });
          return null;
        }

        fail(requestSerial, { kind: 'network', status });

        if (!disposed && followUp && !blocked) {
          followUp = false;
          fetchDocument();
        }

        return null;
      });
    };

    const stop = dispatch(connectStream(PREFERENCES_STREAM, {}, () => ({
      onConnect() {
        if (disposed) {
          return;
        }

        dispatch(quiet({ type: USER_PREFERENCES_CONNECTED }));
        fetchDocument();
      },

      onDisconnect() {
        if (disposed) {
          return;
        }

        dispatch(quiet({ type: USER_PREFERENCES_DISCONNECTED }));
      },

      onReceive(data) {
        if (disposed || !data || data.event !== 'preferences_changed') {
          return;
        }

        const event = parsePreferencesChangedPayload(data.payload);

        if (!event) {
          return;
        }

        dispatch(quiet({
          type: USER_PREFERENCES_EVENT,
          revision: event.revision,
        }));
        fetchDocument();
      },
    })));

    return () => {
      if (disposed) {
        return;
      }

      disposed = true;
      serial += 1;
      followUp = false;
      dispatch(quiet({ type: USER_PREFERENCES_UNSUBSCRIBED }));

      if (typeof stop === 'function') {
        stop();
      }
    };
  };
}
