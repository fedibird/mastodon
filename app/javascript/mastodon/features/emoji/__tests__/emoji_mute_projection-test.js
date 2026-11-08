import { fromJS } from 'immutable';

jest.mock('mastodon/initial_state_data', () => ({
  meta: { me: '1', access_token: 'token' },
}));

jest.mock('mastodon/api', () => {
  const put = jest.fn(() => Promise.resolve({ data: { id: '10', emoji_reactions: [], emoji_reactions_count: 0, emoji_mutes_revision: '2' } }));
  const get = jest.fn(() => Promise.resolve({ data: [] }));
  const api = jest.fn(() => ({ put, get }));
  return { __esModule: true, default: api };
});
import reducer from '../../../reducers/statuses';
import emojiMutes from '../../../reducers/emoji_mutes';
import { EMOJI_REACTION_UPDATE, EMOJI_REACTION_REQUEST } from '../../../actions/interactions';
import { STATUS_IMPORT } from '../../../actions/importer';
import { importEmojiMutes, importEmojiMutesRevision } from '../../../actions/emoji_mutes';
import { projectStreamReaction, reactionNameHidden } from '../emoji_mute_projection';
import { installEmojiMutesForTests, loadEmojiMutes, noteEmojiMutesChanged, appliedEmojiMuteRevision, observedEmojiMuteRevision, resetEmojiMuteStoreForTests } from '../emoji_mute_store';
import api from 'mastodon/api';
import { addEmojiReaction, updateEmojiReaction } from '../../../actions/interactions';
import { refreshEmojiMuteSurfaces, syncEmojiMutes } from '../../../actions/emoji_mutes';
import { ACCOUNTS_IMPORT, STATUSES_IMPORT } from '../../../actions/importer';
import { guardImportedReactions } from '../emoji_mute_projection';
import { NOTIFICATIONS_RELOAD_SUCCESS } from '../../../actions/notifications';
import { KNOWN_EVENT_TYPES } from '../../../stream';

const rules = [{
  effects: { hide_reactions: true },
  emoji: { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' },
}];

describe('emoji mute projection', () => {
  afterEach(() => {
    resetEmojiMuteStoreForTests();
  });
  it('drops only the muted identity and ignores an older stream token', () => {
    let state = reducer(undefined, {
      type: STATUS_IMPORT,
      status: {
        id: '10',
        emoji_reactions_cache_token: '20261109000000000000002',
        emoji_mutes_revision: '4',
        emoji_reactions: [{ name: 'blob', count: 1, account_ids: ['2'] }],
        emoji_reactions_count: 1,
      },
    });

    const incoming = {
      status_id: '10',
      name: 'blob',
      count: 2,
      account_ids: ['2', '3'],
      cache_token: '20261109000000000000001',
      parts: [
        { identity: { kind: 'custom', scope: 'local', custom_emoji_id: '9' }, account_ids: ['2'] },
        { identity: { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' }, account_ids: ['3'] },
      ],
    };
    state = reducer(state, { type: EMOJI_REACTION_UPDATE, emojiReaction: incoming, emojiMuteRules: fromJS(rules) });
    expect(state.getIn(['10', 'emoji_reactions', 0, 'count'])).toBe(1);

    const newer = { ...incoming, cache_token: '20261109000000000000003' };
    state = reducer(state, { type: EMOJI_REACTION_UPDATE, emojiReaction: newer, emojiMuteRules: fromJS(rules) });
    expect(state.getIn(['10', 'emoji_reactions', 0, 'account_ids']).toJS()).toEqual(['2']);
    expect(state.getIn(['10', 'emoji_reactions', 0, 'count'])).toBe(1);

    state = reducer(state, {
      type: STATUS_IMPORT,
      status: {
        id: '10',
        emoji_mutes_revision: '3',
        emoji_reactions: [{ name: 'blob', count: 9, account_ids: ['3'] }],
        emoji_reactions_count: 9,
      },
    });
    expect(state.getIn(['10', 'emoji_reactions_count'])).toBe(1);
    expect(state.getIn(['10', 'emoji_mutes_revision'])).toBe('4');
  });

  it('keeps a newer mute revision and matches unicode without matching a skin tone', () => {
    let mutes = emojiMutes(undefined, importEmojiMutes('2', rules));
    mutes = emojiMutes(mutes, importEmojiMutesRevision('1'));
    expect(mutes.get('revision')).toBe('2');
    mutes = emojiMutes(mutes, importEmojiMutesRevision('3'));
    expect(mutes.get('revision')).toBe('3');

    const unicode = [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '👍🏽' } }];
    expect(reactionNameHidden('👍🏽', null, unicode)).toBe(true);
    expect(reactionNameHidden('👍', null, unicode)).toBe(false);
    expect(projectStreamReaction({ name: 'blob', count: 1, account_ids: ['1'] }, null).hidden).toBe(false);
  });

  it('does not optimistically add a hidden unicode reaction through the real thunk', () => {
    installEmojiMutesForTests({
      revision: '2',
      emoji_mutes: [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '👍🏽' } }],
    });
    const dispatched = [];
    const dispatch = action => {
      if (typeof action === 'function') {
        return action(dispatch, () => fromJS({ meta: { access_token: 'token' } }));
      }

      dispatched.push(action);
      return action;
    };
    addEmojiReaction(fromJS({ id: '10', emoji_reactions: [] }), '👍🏽', null, null, null)(dispatch, () => fromJS({}));
    expect(dispatched.map(action => action.type)).not.toContain(EMOJI_REACTION_REQUEST);
  });

  it('keeps edited text and drops a muted reaction from an anonymous status update', () => {
    installEmojiMutesForTests({
      revision: '2',
      emoji_mutes: [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '👍' } }],
    });
    let state = reducer(undefined, {
      type: STATUS_IMPORT,
      status: { id: '10', content: 'old', emoji_reactions: [], emoji_reactions_count: 0, emoji_mutes_revision: '2' },
    });
    state = reducer(state, {
      type: STATUS_IMPORT,
      status: { id: '10', content: 'edited', emoji_reactions: [{ name: '👍', count: 1, account_ids: ['9'] }], emoji_reactions_count: 1 },
    });
    expect(state.getIn(['10', 'content'])).toBe('edited');
    expect(state.getIn(['10', 'emoji_reactions']).size).toBe(0);
    expect(state.getIn(['10', 'emoji_reactions_count'])).toBe(0);
    expect(state.getIn(['10', 'emoji_mutes_revision'])).toBe('2');
  });

  it('reselects the representative and deletes an empty group from the stream thunk', () => {
    installEmojiMutesForTests({ revision: '4', emoji_mutes: rules });
    let state = reducer(undefined, {
      type: STATUS_IMPORT,
      status: {
        id: '10',
        emoji_reactions_cache_token: '1',
        emoji_reactions: [{ name: 'blob', count: 1, account_ids: ['3'], domain: 'other.example', url: 'https://example.test/remote.png' }],
      },
    });
    const dispatch = action => {
      state = reducer(state, action);
    };
    updateEmojiReaction({
      status_id: '10',
      name: 'blob',
      count: 2,
      account_ids: ['2', '3'],
      domain: 'other.example',
      url: 'https://example.test/remote.png',
      cache_token: '2',
      parts: [
        { identity: { kind: 'custom', scope: 'local', custom_emoji_id: '9' }, custom_emoji_id: '9', account_ids: ['2'], url: 'https://example.test/local.png', domain: null },
        { identity: { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' }, custom_emoji_id: '1', account_ids: ['3'], url: 'https://example.test/remote.png', domain: 'other.example' },
      ],
    })(dispatch);
    expect(state.getIn(['10', 'emoji_reactions', 0, 'url'])).toBe('https://example.test/local.png');
    expect(state.getIn(['10', 'emoji_reactions', 0, 'domain'])).toBeUndefined();
    expect(state.getIn(['10', 'emoji_reactions', 0, 'account_ids']).toJS()).toEqual(['2']);

    updateEmojiReaction({
      status_id: '10',
      name: 'blob',
      count: 1,
      account_ids: ['3'],
      cache_token: '3',
      parts: [
        { identity: { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' }, custom_emoji_id: '11', account_ids: ['3'] },
      ],
    })(dispatch);
    expect(state.getIn(['10', 'emoji_reactions']).size).toBe(0);
  });

  it('keeps an older mute document from replacing a newer applied revision', async () => {
    api.mockImplementation(() => ({
      get: jest.fn(() => Promise.resolve({ data: { revision: '2', emoji_mutes: [] } })),
      put: jest.fn(),
    }));
    await loadEmojiMutes({ force: true });
    expect(appliedEmojiMuteRevision()).toBe('2');

    api.mockImplementation(() => ({
      get: jest.fn(() => Promise.resolve({ data: { revision: '1', emoji_mutes: [{ id: 'stale' }] } })),
      put: jest.fn(),
    }));
    await noteEmojiMutesChanged({ revision: '4' });
    expect(appliedEmojiMuteRevision()).toBe('2');
    expect(observedEmojiMuteRevision()).toBe('4');
  });

  it('does not adopt an older rest projection for a status that is not cached yet', () => {
    installEmojiMutesForTests({
      revision: '5',
      emoji_mutes: [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '👍' } }],
    });
    const state = reducer(undefined, {
      type: STATUS_IMPORT,
      status: {
        id: 'late',
        content: 'edited after the mute',
        emoji_mutes_revision: '4',
        emoji_reactions: [{ name: '👍', count: 1, account_ids: ['9'] }],
        emoji_reactions_count: 1,
      },
    });
    expect(state.getIn(['late', 'content'])).toBe('edited after the mute');
    expect(state.getIn(['late', 'emoji_reactions']).size).toBe(0);
    expect(state.getIn(['late', 'emoji_mutes_revision'])).toBe('5');

    const incoming = {
      id: 'late',
      content: 'edited after the mute',
      emoji_mutes_revision: '4',
      emoji_reactions: [{ name: '👍', count: 1, account_ids: ['9'] }],
      emoji_reactions_count: 1,
    };
    const hide = [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '👍' } }];
    [true, false].forEach(accepted => {
      const next = guardImportedReactions(undefined, incoming, hide, accepted, '5');
      expect(next.content).toBe('edited after the mute');
      expect(next.emoji_reactions === undefined || next.emoji_reactions.length === 0).toBe(true);
      expect(next.emoji_mutes_revision).toBe('5');
    });

    const kept = guardImportedReactions(fromJS({
      id: 'kept',
      content: 'newer text',
      emoji_mutes_revision: '6',
      emoji_reactions: [],
      emoji_reactions_count: 0,
    }), { ...incoming, id: 'kept', content: 'older text' }, hide, true, '5');
    expect(kept.emoji_mutes_revision).toBe('6');
    expect(kept.emoji_reactions).toEqual([]);
  });

  it('imports notification accounts before replacing the list, ignores a failed list, and keeps the newest refresh', async () => {
    const account = {
      id: 'acct-1',
      acct: 'a',
      username: 'a',
      display_name: 'A',
      note: '',
      followed_message: '',
      url: 'https://example.test/a',
      emojis: [],
      fields: [],
    };
    const target = { ...account, id: 'acct-2', acct: 'b', username: 'b', display_name: 'B', url: 'https://example.test/b' };
    const notification = {
      id: 'n1',
      type: 'emoji_reaction',
      account,
      report: { target_account: target },
      status: {
        id: 'st-1',
        account,
        content: '<p>post</p>',
        spoiler_text: '',
        emojis: [],
        media_attachments: [],
        mentions: [],
        emoji_reactions: [],
        emoji_reactions_count: 0,
        emoji_mutes_revision: '5',
      },
    };
    const calls = [];
    api.mockImplementation(() => ({
      get: url => {
        const path = String(url);
        calls.push(path);
        if (path.includes('emoji_mutes')) {
          return Promise.resolve({ data: { revision: '5', emoji_mutes: [] } });
        }
        if (path.includes('unread_count')) {
          return Promise.resolve({ data: { count: 1 } });
        }
        if (path.includes('notifications')) {
          return Promise.resolve({ data: [notification] });
        }
        return Promise.resolve({ data: { id: path.split('/').pop(), content: 's', emoji_reactions: [], emoji_reactions_count: 0, emoji_mutes_revision: '5' } });
      },
      put: jest.fn(),
    }));
    const actions = [];
    const dispatch = action => {
      if (typeof action === 'function') {
        return action(dispatch, () => fromJS({
          statuses: {},
          accounts: {},
          polls: {},
          externalBoosts: {},
          contexts: {},
          timelines: {},
          meta: { access_token: 'token' },
        }));
      }
      actions.push(action);
      return action;
    };
    await syncEmojiMutes()(dispatch, () => fromJS({ contexts: {}, timelines: {}, statuses: {} }));
    const reloadAt = actions.findIndex(action => action.type === NOTIFICATIONS_RELOAD_SUCCESS);
    const accountAt = actions.findIndex(action => action.type === ACCOUNTS_IMPORT && action.accounts.some(item => item.id === 'acct-1'));
    const targetAt = actions.findIndex(action => action.type === ACCOUNTS_IMPORT && action.accounts.some(item => item.id === 'acct-2'));
    const statusAt = actions.findIndex(action => action.type === STATUSES_IMPORT && action.statuses.some(item => item.id === 'st-1'));
    expect(accountAt).toBeGreaterThanOrEqual(0);
    expect(targetAt).toBeGreaterThanOrEqual(0);
    expect(statusAt).toBeGreaterThanOrEqual(0);
    expect(reloadAt).toBeGreaterThan(accountAt);
    expect(reloadAt).toBeGreaterThan(targetAt);
    expect(reloadAt).toBeGreaterThan(statusAt);
    expect(actions[reloadAt].notifications[0].status.id).toBe('st-1');

    actions.length = 0;
    api.mockImplementation(() => ({
      get: url => (String(url).includes('notifications') && !String(url).includes('unread')
        ? Promise.reject(new Error('503'))
        : Promise.resolve({ data: { count: 7 } })),
      put: jest.fn(),
    }));
    await refreshEmojiMuteSurfaces()(dispatch, () => fromJS({ contexts: {}, timelines: {}, statuses: {} }));
    expect(actions.map(action => action.type)).not.toContain(NOTIFICATIONS_RELOAD_SUCCESS);

    api.mockImplementation(() => ({
      get: url => Promise.resolve({ data: String(url).includes('unread_count') ? { count: 0 } : [] }),
      put: jest.fn(),
    }));
    await refreshEmojiMuteSurfaces()(dispatch, () => fromJS({ contexts: {}, timelines: {}, statuses: {} }));
    expect(actions.filter(action => action.type === NOTIFICATIONS_RELOAD_SUCCESS)).toEqual([
      expect.objectContaining({ notifications: [], unread: 0 }),
    ]);
  });

  it('keeps the newer notification refresh when an older one finishes last and refetches every column', async () => {
    const pending = [];
    const requested = [];
    api.mockImplementation(() => ({
      get: url => {
        const path = String(url);
        requested.push(path);
        if (path.includes('unread_count') || (path.includes('notifications') && !path.includes('unread'))) {
          return new Promise(resolve => pending.push({ path, resolve }));
        }
        return Promise.resolve({ data: { id: path.split('/').pop(), content: '<p>post</p>', spoiler_text: '', emojis: [], media_attachments: [], mentions: [], emoji_reactions: [{ name: '👍', count: 1, account_ids: ['1'] }], emoji_reactions_count: 1, emoji_mutes_revision: '6' } });
      },
      put: jest.fn(),
    }));
    const home = Array.from({ length: 41 }, (_item, index) => String(index + 1));
    const state = () => fromJS({
      contexts: { references: { thread: ['detail-status'] } },
      timelines: { home: { items: home }, local: { items: ['column-b'] } },
      statuses: { 'open-detail': { emoji_reactions: [{ name: '👍' }] } },
    });
    const actions = [];
    const dispatch = action => {
      if (typeof action === 'function') {
        return action(dispatch, state);
      }
      actions.push(action);
      return action;
    };
    const flush = () => new Promise(resolve => setTimeout(resolve, 0));
    const first = refreshEmojiMuteSurfaces()(dispatch, state);
    await flush();
    const firstNotifications = pending.find(item => item.path.includes('notifications') && !item.path.includes('unread'));
    const second = refreshEmojiMuteSurfaces()(dispatch, state);
    await flush();
    const secondNotifications = pending.filter(item => item.path.includes('notifications') && !item.path.includes('unread')).pop();
    secondNotifications.resolve({ data: [] });
    await flush();
    pending.filter(item => item.path.includes('unread_count')).pop().resolve({ data: { count: 0 } });
    await second;
    firstNotifications.resolve({ data: [{ id: 'old', type: 'mention', account: { id: 'acct-1', username: 'a', display_name: 'A', note: '', followed_message: '', url: 'https://example.test/a', emojis: [] } }] });
    await first;
    const reloads = actions.filter(action => action.type === NOTIFICATIONS_RELOAD_SUCCESS);
    expect(reloads).toHaveLength(1);
    expect(reloads[0].notifications).toEqual([]);
    expect(reloads[0].unread).toBe(0);
    expect(requested).toEqual(expect.arrayContaining([
      '/api/v1/statuses/41',
      '/api/v1/statuses/column-b',
      '/api/v1/statuses/detail-status',
      '/api/v1/statuses/open-detail',
    ]));
  });

  it('registers the mute change event for EventSource', () => {
    expect(KNOWN_EVENT_TYPES).toContain('emoji_mutes_changed');
    expect(reactionNameHidden('‼️', null, [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '‼' } }])).toBe(false);
    expect(reactionNameHidden('1⃣', null, [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '1️⃣' } }])).toBe(false);
  });
});
