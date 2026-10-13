import { connectUserStream } from '../actions/streaming';
import { connectUserPreferences } from '../actions/user_preferences';

// The signed-in WebUI keeps the ordinary user stream and the preferences
// stream on the shared socket. Unmount stops each subscription on its own.
export const startMastodonSubscriptions = (store) => {
  const disconnectUser = store.dispatch(connectUserStream());
  const disconnectPreferences = store.dispatch(connectUserPreferences());
  let stopped = false;

  return () => {
    if (stopped) {
      return;
    }

    stopped = true;

    if (typeof disconnectUser === 'function') {
      disconnectUser();
    }

    if (typeof disconnectPreferences === 'function') {
      disconnectPreferences();
    }
  };
};
