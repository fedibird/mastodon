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

  it('registers the mute change event for EventSource', () => {
    expect(KNOWN_EVENT_TYPES).toContain('emoji_mutes_changed');
    expect(reactionNameHidden('‼️', null, [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '‼' } }])).toBe(false);
    expect(reactionNameHidden('1⃣', null, [{ effects: { hide_reactions: true }, emoji: { kind: 'unicode', native: '1️⃣' } }])).toBe(false);
  });
});
