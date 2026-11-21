import { Map as ImmutableMap, fromJS } from 'immutable';

jest.mock('mastodon/initial_state_data', () => ({
  meta: { me: '1', access_token: 'token' },
}));

jest.mock('mastodon/api', () => {
  const get = jest.fn();
  const patch = jest.fn();
  return { __esModule: true, default: jest.fn(() => ({ get, patch })) };
});

jest.mock('mastodon/features/emoji/emoji_mute_boot_bypass', () => ({
  emojiMuteBypassEnabled: jest.fn(() => false),
}));

import api from 'mastodon/api';
import reducer from 'mastodon/reducers/emoji_mutes';
import notificationsReducer from 'mastodon/reducers/notifications';
import {
  applyRemoteEmojiMutePreference,
  ignoreEmojiMutesThisView,
  syncEmojiMutes,
} from 'mastodon/actions/emoji_mutes';
import {
  currentEmojiMutes,
  installEmojiMutesForTests,
  loadEmojiMutes,
  resetEmojiMuteStoreForTests,
} from '../emoji_mute_store';
import { currentEmojiMuteBoot } from '../emoji_mute_availability';

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};

const hideRule = {
  id: '15',
  emoji: { kind: 'unicode', native: '👍' },
  effects: { hide_reactions: true },
};

const flush = () => new Promise(resolve => {
  setTimeout(resolve, 0);
});

describe('emoji mute preference flow', () => {
  let emojiMutes;
  let notifications;

  const root = () => ImmutableMap({
    emojiMutes,
    notifications,
    settings: fromJS({ notifications: { quickFilter: { active: 'mention' } } }),
    markers: ImmutableMap(),
    contexts: ImmutableMap(),
    timelines: ImmutableMap(),
    statuses: ImmutableMap(),
    relationships: ImmutableMap(),
  });

  const dispatch = action => {
    if (typeof action === 'function') {
      return action(dispatch, root);
    }

    if (action && action.type) {
      emojiMutes = reducer(emojiMutes, action);
      notifications = notificationsReducer(notifications, action);
    }

    return action;
  };

  beforeEach(() => {
    resetEmojiMuteStoreForTests();
    api().get.mockReset();
    api().patch.mockReset();
    emojiMutes = reducer(undefined, { type: '@@INIT' });
    notifications = notificationsReducer(undefined, { type: '@@INIT' });
    notifications = notifications.set('emojiMuteWithheld', fromJS([
      { bucket: 'items', notification: { id: '9', type: 'emoji_reaction', emoji: '👍' } },
    ]));
  });

  it('adopts enabled false from the list payload and drops a delayed older list', async () => {
    installEmojiMutesForTests({ revision: '3', emoji_mutes: [hideRule] });
    api().get.mockResolvedValueOnce({
      data: { revision: '4', enabled: false, emoji_mutes: [hideRule] },
    });

    await loadEmojiMutes({ force: true });

    expect(currentEmojiMuteBoot().availability).toBe('disabled');
    expect(currentEmojiMutes()).toEqual([]);

    api().get.mockResolvedValueOnce({
      data: { revision: '2', enabled: true, emoji_mutes: [hideRule] },
    });
    await loadEmojiMutes({ force: true });

    expect(currentEmojiMuteBoot().availability).toBe('disabled');
    expect(currentEmojiMutes()).toEqual([]);
  });

  it('drops an in-flight list after another tab turns the feature off', async () => {
    const pending = deferred();
    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        return pending.promise;
      }

      return Promise.resolve({ data: [] });
    });

    const request = loadEmojiMutes({ force: true });
    await dispatch(applyRemoteEmojiMutePreference(false));
    pending.resolve({ data: { revision: '4', enabled: true, emoji_mutes: [hideRule] } });
    await request;

    expect(currentEmojiMuteBoot().availability).toBe('disabled');
    expect(currentEmojiMutes()).toEqual([]);
  });

  it('restores withheld notifications when this view ignores mutes', async () => {
    installEmojiMutesForTests({ revision: '3', emoji_mutes: [hideRule] });
    api().get.mockImplementation(url => {
      if (url === '/api/v1/notifications/unread_count') {
        return Promise.resolve({ data: { count: 1 } });
      }

      return Promise.resolve({ data: [] });
    });

    const pending = dispatch(ignoreEmojiMutesThisView());
    expect(notifications.get('items').some(item => item && item.get('id') === '9')).toBe(true);
    expect(notifications.get('emojiMuteWithheld').size).toBe(0);
    await pending;
    expect(api().get).toHaveBeenCalledWith('/api/v1/notifications', expect.any(Object));
    expect(emojiMutes.get('availability')).toBe('temporary_ignore');
    expect(emojiMutes.get('display')).toBe('show');
  });

  it('does not let a slow ignore refresh replace a newer enabled document', async () => {
    installEmojiMutesForTests({ revision: '3', emoji_mutes: [hideRule] });
    const notificationCalls = [];

    api().get.mockImplementation(url => {
      if (url === '/api/v1/notifications') {
        const pending = deferred();
        notificationCalls.push(pending);
        return pending.promise;
      }

      if (url === '/api/v1/notifications/unread_count') {
        return Promise.resolve({ data: { count: 0 } });
      }

      if (url === '/api/v1/fedibird/emoji_mutes') {
        return Promise.resolve({ data: { revision: '8', enabled: true, emoji_mutes: [] } });
      }

      return Promise.resolve({ data: [] });
    });

    const ignored = dispatch(ignoreEmojiMutesThisView());
    await flush();
    const enabled = dispatch(applyRemoteEmojiMutePreference(true));
    await flush();
    expect(notificationCalls.length).toBeGreaterThanOrEqual(2);

    notificationCalls[0].resolve({ data: [{ id: 'stale', type: 'mention' }] });
    notificationCalls[1].resolve({ data: [] });
    await ignored;
    await enabled;

    expect(notifications.get('items').some(item => item && item.get('id') === 'stale')).toBe(false);
    expect(currentEmojiMuteBoot().availability).toBe('enabled');
  });

  it('keeps ignore in place when the in-flight list fails', async () => {
    installEmojiMutesForTests({ revision: '3', emoji_mutes: [hideRule] });
    const pending = deferred();

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        return pending.promise;
      }

      return Promise.resolve({ data: [] });
    });

    const loading = syncEmojiMutes()(dispatch, root);
    await dispatch(ignoreEmojiMutesThisView());
    pending.reject(Object.assign(new Error('timeout'), { code: 'ECONNABORTED' }));
    await expect(loading).resolves.toBeNull();
    expect(emojiMutes.get('availability')).toBe('temporary_ignore');
    expect(emojiMutes.get('phase')).not.toBe('error');
  });

  it('does not adopt a list that arrives after this view ignores mutes', async () => {
    installEmojiMutesForTests({ revision: '3', emoji_mutes: [hideRule] });
    const pending = deferred();

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        return pending.promise;
      }

      return Promise.resolve({ data: [] });
    });

    const loading = syncEmojiMutes()(dispatch, root);
    await dispatch(ignoreEmojiMutesThisView());
    pending.resolve({ data: { revision: '9', enabled: true, emoji_mutes: [hideRule] } });
    await loading;
    expect(emojiMutes.get('availability')).toBe('temporary_ignore');
    expect(currentEmojiMutes()).toEqual([]);
  });

  it('does not refresh notifications on the first document fetch', async () => {
    api().get.mockResolvedValue({ data: { revision: '1', enabled: true, emoji_mutes: [] } });

    await syncEmojiMutes({ bootstrap: true })(dispatch, root);
    const urls = api().get.mock.calls.map(call => call[0]);
    expect(urls).toContain('/api/v1/fedibird/emoji_mutes');
    expect(urls).not.toContain('/api/v1/notifications');
  });
});
