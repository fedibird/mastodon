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
  bootStandaloneEmojiMutes,
  disableEmojiMuteFeature,
  enableEmojiMuteLoading,
  ignoreEmojiMutesThisView,
  retryEmojiMuteLoad,
  syncEmojiMutes,
} from 'mastodon/actions/emoji_mutes';
import {
  appliedEmojiMuteRevision,
  applyEmojiMuteDisabledDocument,
  currentEmojiMutes,
  emojiMuteDocumentReady,
  emojiReactionEventsAccepted,
  installEmojiMutesForTests,
  loadEmojiMutes,
  noteEmojiMutesChanged,
  resetEmojiMuteSession,
  resetEmojiMuteStoreForTests,
} from '../emoji_mute_store';
import { currentEmojiMuteBoot, noteEmojiMuteDisabledLocally, noteEmojiMuteEnabledLocally } from '../emoji_mute_availability';

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

      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return Promise.resolve({ data: { enabled: false, explicit: true, known: true } });
      }

      return Promise.resolve({ data: [] });
    });

    const request = loadEmojiMutes({ force: true });
    await dispatch(applyRemoteEmojiMutePreference());
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

      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return Promise.resolve({ data: { enabled: true, explicit: true, known: true } });
      }

      if (url === '/api/v1/fedibird/emoji_mutes') {
        return Promise.resolve({ data: { revision: '8', enabled: true, emoji_mutes: [] } });
      }

      return Promise.resolve({ data: [] });
    });

    const ignored = dispatch(ignoreEmojiMutesThisView());
    await flush();
    const enabled = dispatch(applyRemoteEmojiMutePreference());
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

  it('ignores an older preference read that arrives after a newer one', async () => {
    noteEmojiMuteDisabledLocally();
    const reads = [];

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        const pending = deferred();
        reads.push(pending);
        return pending.promise;
      }

      if (url === '/api/v1/fedibird/emoji_mutes') {
        return Promise.resolve({ data: { revision: '4', enabled: true, emoji_mutes: [hideRule] } });
      }

      return Promise.resolve({ data: [] });
    });

    const older = dispatch(applyRemoteEmojiMutePreference());
    const newer = dispatch(applyRemoteEmojiMutePreference());
    reads[1].resolve({ data: { enabled: true, explicit: true, known: true } });
    await newer;
    reads[0].resolve({ data: { enabled: false, explicit: true, known: true } });
    await older;

    expect(currentEmojiMuteBoot().availability).toBe('enabled');
    expect(currentEmojiMutes()).toEqual([hideRule]);
  });

  it('reads the saved preference on reconnect and skips that read at startup', async () => {
    noteEmojiMuteDisabledLocally();
    await syncEmojiMutes()(dispatch, root);
    expect(api().get).not.toHaveBeenCalled();

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return Promise.resolve({ data: { enabled: true, explicit: true, known: true } });
      }

      if (url === '/api/v1/fedibird/emoji_mutes') {
        return Promise.resolve({ data: { revision: '2', enabled: true, emoji_mutes: [hideRule] } });
      }

      return Promise.resolve({ data: [] });
    });

    await syncEmojiMutes({ reconnect: true })(dispatch, root);
    const urls = api().get.mock.calls.map(call => call[0]);
    expect(urls).toContain('/api/v1/fedibird/emoji_mute_preference');
    expect(urls).toContain('/api/v1/fedibird/emoji_mutes');
    expect(currentEmojiMuteBoot().availability).toBe('enabled');
    expect(emojiMutes.get('display')).toBe('apply');
  });

  it('fetches rules when a confirmed enabled preference finds the document unready', async () => {
    noteEmojiMuteEnabledLocally();
    const list = deferred();
    const preference = deferred();
    let muteGets = 0;

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        muteGets += 1;
        return muteGets === 1
          ? list.promise
          : Promise.resolve({ data: { revision: '5', enabled: true, emoji_mutes: [hideRule] } });
      }

      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return preference.promise;
      }

      return Promise.resolve({ data: [] });
    });

    const boot = syncEmojiMutes({ bootstrap: true })(dispatch, root);
    const reading = dispatch(applyRemoteEmojiMutePreference());
    preference.resolve({ data: { enabled: true, explicit: true, known: true } });
    await reading;
    expect(muteGets).toBe(2);

    list.resolve({ data: { revision: '4', enabled: false, emoji_mutes: [] } });
    await boot;

    expect(currentEmojiMuteBoot().availability).toBe('enabled');
    expect(emojiMuteDocumentReady()).toBe(true);
    expect(currentEmojiMutes()).toEqual([hideRule]);
  });

  it('does not fetch rules when the enabled preference matches a ready document', async () => {
    noteEmojiMuteEnabledLocally();
    installEmojiMutesForTests({ revision: '3', emoji_mutes: [hideRule] });
    api().get.mockResolvedValue({ data: { enabled: true, explicit: true, known: true } });

    await dispatch(applyRemoteEmojiMutePreference());

    expect(api().get.mock.calls.map(call => call[0])).toEqual(['/api/v1/fedibird/emoji_mute_preference']);
    expect(currentEmojiMutes()).toEqual([hideRule]);
  });

  it('does not let an older disabled list drop a newer preference read', async () => {
    const list = deferred();
    const preference = deferred();
    let muteGets = 0;

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        muteGets += 1;
        return muteGets === 1
          ? list.promise
          : Promise.resolve({ data: { revision: '5', enabled: true, emoji_mutes: [hideRule] } });
      }

      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return preference.promise;
      }

      return Promise.resolve({ data: [] });
    });

    const loading = loadEmojiMutes();
    const reading = dispatch(applyRemoteEmojiMutePreference());
    list.resolve({ data: { revision: '4', enabled: false, emoji_mutes: [hideRule] } });
    await loading;
    expect(currentEmojiMuteBoot().availability).not.toBe('disabled');

    preference.resolve({ data: { enabled: true, explicit: true, known: true } });
    await reading;

    expect(currentEmojiMuteBoot().availability).toBe('enabled');
    expect(emojiMuteDocumentReady()).toBe(true);
    expect(currentEmojiMutes()).toEqual([hideRule]);
  });

  it('does not reuse the first fetch after a preference change invalidated it', async () => {
    const first = deferred();
    let preferenceEnabled = false;
    let muteGets = 0;

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        muteGets += 1;
        return muteGets === 1
          ? first.promise
          : Promise.resolve({ data: { revision: '2', enabled: true, emoji_mutes: [] } });
      }

      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return Promise.resolve({ data: { enabled: preferenceEnabled, explicit: true, known: true } });
      }

      return Promise.resolve({ data: [] });
    });

    const boot = syncEmojiMutes({ bootstrap: true })(dispatch, root);
    await dispatch(applyRemoteEmojiMutePreference());
    preferenceEnabled = true;
    await dispatch(applyRemoteEmojiMutePreference());
    first.resolve({ data: { revision: '1', enabled: false, emoji_mutes: [hideRule] } });
    await boot;

    expect(muteGets).toBe(2);
    expect(currentEmojiMuteBoot().availability).toBe('enabled');
    expect(emojiMuteDocumentReady()).toBe(true);
  });

  it('drops a preference read that started before the viewer changed', async () => {
    const pending = deferred();

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return pending.promise;
      }

      return Promise.resolve({ data: [] });
    });

    noteEmojiMuteEnabledLocally();
    const older = dispatch(applyRemoteEmojiMutePreference());
    resetEmojiMuteSession();
    pending.resolve({ data: { enabled: false, explicit: true, known: true } });
    await older;

    expect(currentEmojiMuteBoot().availability).toBe('enabled');
  });

  it('does not let a delayed off save replace a newer confirmed on', async () => {
    noteEmojiMuteEnabledLocally();
    const patch = deferred();
    api().patch.mockImplementation(() => patch.promise);
    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return Promise.resolve({ data: { enabled: true, explicit: true, known: true, preference_revision: '9' } });
      }

      if (url === '/api/v1/fedibird/emoji_mutes') {
        return Promise.resolve({ data: { revision: '3', enabled: true, emoji_mutes: [] } });
      }

      return Promise.resolve({ data: [] });
    });

    const saving = dispatch(disableEmojiMuteFeature());
    await dispatch(applyRemoteEmojiMutePreference());
    expect(currentEmojiMuteBoot().availability).toBe('enabled');

    patch.resolve({ data: { enabled: false, explicit: true, known: true, preference_revision: '4' } });
    await saving;

    expect(currentEmojiMuteBoot().availability).toBe('enabled');
  });

  it('reads the current preference when the save response is lost', async () => {
    noteEmojiMuteEnabledLocally();
    api().patch.mockRejectedValueOnce(Object.assign(new Error('timeout'), { code: 'ECONNABORTED' }));
    api().get.mockResolvedValueOnce({ data: { enabled: true, explicit: true, known: true, preference_revision: '6' } });

    const saved = await dispatch(disableEmojiMuteFeature());

    expect(saved.enabled).toBe(true);
    expect(currentEmojiMuteBoot().availability).toBe('enabled');
    expect(emojiMutes.get('availability')).not.toBe('disabled');
  });

  it('hides emoji when a known-off tab cannot confirm the preference after reconnect', async () => {
    noteEmojiMuteDisabledLocally();
    api().get.mockRejectedValueOnce(Object.assign(new Error('timeout'), { code: 'ECONNABORTED' }));

    await syncEmojiMutes({ reconnect: true })(dispatch, root);

    expect(emojiMutes.get('display')).toBe('suppress');
    expect(emojiMutes.get('phase')).toBe('error');
    expect(emojiMutes.get('availability')).toBe('unknown');
  });

  it('does not fetch a preference while a known-off tab is loading for the first time', async () => {
    noteEmojiMuteDisabledLocally();

    await syncEmojiMutes({ bootstrap: true })(dispatch, root);

    expect(api().get).not.toHaveBeenCalled();
    expect(currentEmojiMuteBoot().availability).toBe('disabled');
  });

  it('loads standalone compose rules without blocking the composer', async () => {
    noteEmojiMuteEnabledLocally();
    const list = deferred();
    api().get.mockImplementation(url => (
      url === '/api/v1/fedibird/emoji_mutes' ? list.promise : Promise.resolve({ data: [] })
    ));

    const loading = dispatch(bootStandaloneEmojiMutes());
    expect(api().get.mock.calls.map(call => call[0])).toContain('/api/v1/fedibird/emoji_mutes');

    list.resolve({
      data: {
        revision: '2',
        enabled: true,
        emoji_mutes: [hideRule],
      },
    });
    await loading;

    expect(currentEmojiMutes()).toEqual([hideRule]);
    expect(emojiMuteDocumentReady()).toBe(true);
  });

  it('does not let an older preference read undo a mute saved in this tab', async () => {
    const pending = deferred();

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return pending.promise;
      }

      if (url === '/api/v1/fedibird/emoji_mutes') {
        return Promise.resolve({ data: { revision: '3', enabled: true, emoji_mutes: [hideRule] } });
      }

      return Promise.resolve({ data: [] });
    });

    const older = dispatch(applyRemoteEmojiMutePreference());
    dispatch(enableEmojiMuteLoading());
    pending.resolve({ data: { enabled: false, explicit: true, known: true } });
    await older;

    expect(currentEmojiMuteBoot().availability).toBe('enabled');
  });

  it('does not let an older preference read turn the feature back on after this tab saves off', async () => {
    noteEmojiMuteDisabledLocally();
    const pending = deferred();

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        return pending.promise;
      }

      return Promise.resolve({ data: { revision: '3', enabled: true, emoji_mutes: [hideRule] } });
    });
    api().patch.mockResolvedValue({ data: { enabled: false, explicit: true } });

    const older = dispatch(applyRemoteEmojiMutePreference());
    await dispatch(disableEmojiMuteFeature());
    pending.resolve({ data: { enabled: true, explicit: true, known: true } });
    await older;

    expect(currentEmojiMuteBoot().availability).toBe('disabled');
    expect(api().get.mock.calls.map(call => call[0])).not.toContain('/api/v1/fedibird/emoji_mutes');
  });

  it('does not refresh notifications when the stream connects during the first fetch', async () => {
    const pending = deferred();

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        return pending.promise;
      }

      return Promise.resolve({ data: [] });
    });

    const boot = syncEmojiMutes({ bootstrap: true })(dispatch, root);
    const connect = syncEmojiMutes()(dispatch, root);
    pending.resolve({ data: { revision: '1', enabled: true, emoji_mutes: [] } });
    await boot;
    await connect;

    const urls = api().get.mock.calls.map(call => call[0]);
    expect(urls.filter(url => url === '/api/v1/fedibird/emoji_mutes')).toHaveLength(1);
    expect(urls).not.toContain('/api/v1/notifications');
  });

  it('does not refresh notifications on the first document fetch', async () => {
    api().get.mockResolvedValue({ data: { revision: '1', enabled: true, emoji_mutes: [] } });

    await syncEmojiMutes({ bootstrap: true })(dispatch, root);
    const urls = api().get.mock.calls.map(call => call[0]);
    expect(urls).toContain('/api/v1/fedibird/emoji_mutes');
    expect(urls).not.toContain('/api/v1/notifications');
  });

  it('keeps the rules revision separate from the preference stamp and refetches a later stream notice', async () => {
    api().get.mockResolvedValueOnce({
      data: {
        revision: '3',
        preference_revision: '1700000000000000',
        enabled: true,
        emoji_mutes: [hideRule],
      },
    });

    await loadEmojiMutes();
    expect(appliedEmojiMuteRevision()).toBe('3');

    const next = deferred();
    api().get.mockImplementation(url => (
      url === '/api/v1/fedibird/emoji_mutes' ? next.promise : Promise.resolve({ data: [] })
    ));

    const reloading = noteEmojiMutesChanged({ revision: '4' });
    expect(api().get.mock.calls.filter(call => call[0] === '/api/v1/fedibird/emoji_mutes')).toHaveLength(2);

    next.resolve({
      data: {
        revision: '4',
        preference_revision: '1700000000000000',
        enabled: true,
        emoji_mutes: [],
      },
    });
    await reloading;
    expect(appliedEmojiMuteRevision()).toBe('4');
  });

  it('withholds reaction notifications while a known-off tab confirms the preference', async () => {
    noteEmojiMuteDisabledLocally();
    applyEmojiMuteDisabledDocument();
    expect(emojiReactionEventsAccepted()).toBe(true);

    const pending = deferred();
    api().get.mockImplementation(url => (
      url === '/api/v1/fedibird/emoji_mute_preference' ? pending.promise : Promise.resolve({ data: [] })
    ));

    const confirming = syncEmojiMutes({ reconnect: true })(dispatch, root);
    expect(emojiReactionEventsAccepted()).toBe(false);
    expect(emojiMuteDocumentReady()).toBe(false);

    dispatch({
      type: 'NOTIFICATIONS_UPDATE',
      notification: {
        id: '8',
        type: 'emoji_reaction',
        account: { id: '1' },
        emoji_reaction: { name: '😀' },
      },
    });

    const held = notifications.get('emojiMuteWithheld').some(entry => entry.getIn(['notification', 'id']) === '8');
    expect(held).toBe(true);
    expect(notifications.get('items').some(item => item && item.get('id') === '8')).toBe(false);

    pending.resolve({ data: { enabled: false, explicit: true, known: true, preference_revision: '3' } });
    await confirming;

    expect(currentEmojiMuteBoot().availability).toBe('disabled');
    expect(emojiReactionEventsAccepted()).toBe(true);
  });

  it('does not let an older confirmation failure replace a newer preference', async () => {
    noteEmojiMuteDisabledLocally();
    applyEmojiMuteDisabledDocument();
    const first = deferred();
    let preferenceReads = 0;

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        preferenceReads += 1;
        if (preferenceReads === 1) {
          return first.promise;
        }

        return Promise.resolve({ data: { enabled: true, explicit: true, known: true, preference_revision: '8' } });
      }

      if (url === '/api/v1/fedibird/emoji_mutes') {
        return Promise.resolve({ data: { revision: '1', enabled: true, emoji_mutes: [] } });
      }

      return Promise.resolve({ data: [] });
    });

    const older = syncEmojiMutes({ reconnect: true })(dispatch, root);
    expect(emojiReactionEventsAccepted()).toBe(false);

    await dispatch(applyRemoteEmojiMutePreference());
    first.reject(Object.assign(new Error('timeout'), { code: 'ECONNABORTED' }));
    await older;

    expect(emojiMutes.get('availability')).toBe('enabled');
    expect(emojiMutes.get('phase')).not.toBe('error');
    expect(emojiMuteDocumentReady()).toBe(true);
  });

  it('retries a failed standalone rules load without reloading the page', async () => {
    noteEmojiMuteEnabledLocally();
    let rulesFetches = 0;
    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        rulesFetches += 1;
        if (rulesFetches === 1) {
          return Promise.reject(new Error('offline'));
        }

        return Promise.resolve({ data: { revision: '2', enabled: true, emoji_mutes: [] } });
      }

      return Promise.resolve({ data: [] });
    });

    await dispatch(bootStandaloneEmojiMutes());
    expect(emojiMutes.get('phase')).toBe('error');

    await dispatch(retryEmojiMuteLoad());

    expect(rulesFetches).toBe(2);
    expect(emojiMutes.get('phase')).toBe('ready');
    expect(appliedEmojiMuteRevision()).toBe('2');
  });

  it('moves a failed newer preference read during confirmation onto the recovery notice', async () => {
    noteEmojiMuteDisabledLocally();
    applyEmojiMuteDisabledDocument();
    const first = deferred();
    let preferenceReads = 0;

    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mute_preference') {
        preferenceReads += 1;
        if (preferenceReads === 1) {
          return first.promise;
        }

        return Promise.reject(Object.assign(new Error('timeout'), { code: 'ECONNABORTED' }));
      }

      return Promise.resolve({ data: [] });
    });

    const older = syncEmojiMutes({ reconnect: true })(dispatch, root);
    expect(emojiMutes.get('phase')).toBe('loading');
    expect(emojiMutes.get('display')).toBe('suppress');

    await dispatch(applyRemoteEmojiMutePreference());
    expect(emojiMutes.get('phase')).toBe('error');
    expect(emojiMutes.get('failure')).toBe('unavailable');
    expect(emojiMutes.get('display')).toBe('suppress');
    expect(emojiReactionEventsAccepted()).toBe(false);

    first.resolve({ data: { enabled: false, explicit: true, known: true, preference_revision: '4' } });
    await older;

    expect(emojiMutes.get('phase')).toBe('error');
    expect(emojiMutes.get('availability')).toBe('unknown');
    expect(currentEmojiMuteBoot().availability).toBe('unknown');
    expect(emojiReactionEventsAccepted()).toBe(false);
  });

  it('accepts the default off preference on reconnect without loading rules', async () => {
    noteEmojiMuteDisabledLocally();
    applyEmojiMuteDisabledDocument();
    api().get.mockResolvedValue({
      data: { enabled: false, explicit: false, known: true, preference_revision: '0' },
    });

    await syncEmojiMutes({ reconnect: true })(dispatch, root);

    const urls = api().get.mock.calls.map(call => call[0]);
    expect(urls).toContain('/api/v1/fedibird/emoji_mute_preference');
    expect(urls.filter(url => url === '/api/v1/fedibird/emoji_mutes')).toEqual([]);
    expect(emojiMutes.get('phase')).toBe('ready');
    expect(emojiMutes.get('display')).toBe('show');
    expect(emojiMutes.get('availability')).toBe('disabled');
    expect(emojiMutes.get('failure')).toBe(null);
    expect(emojiReactionEventsAccepted()).toBe(true);
  });

  it('does not treat an unset preference row as a saved off', async () => {
    noteEmojiMuteEnabledLocally();
    api().patch.mockResolvedValue({
      data: { enabled: false, explicit: false, known: true, preference_revision: '0' },
    });

    await expect(dispatch(disableEmojiMuteFeature())).rejects.toThrow(/not saved/);
    expect(currentEmojiMuteBoot().availability).toBe('enabled');
    expect(emojiMutes.get('availability')).toBe('unknown');
  });

  it('treats a malformed preference response during confirmation as a failure', async () => {
    noteEmojiMuteDisabledLocally();
    api().get.mockResolvedValueOnce({ data: { enabled: 'no', explicit: true } });

    await syncEmojiMutes({ reconnect: true })(dispatch, root);

    expect(emojiMutes.get('phase')).toBe('error');
    expect(emojiMutes.get('display')).toBe('suppress');
    expect(emojiMutes.get('availability')).toBe('unknown');
    expect(emojiReactionEventsAccepted()).toBe(false);
  });
});
