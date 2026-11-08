import { fromJS } from 'immutable';
import reducer from '../../../reducers/statuses';
import emojiMutes from '../../../reducers/emoji_mutes';
import { EMOJI_REACTION_UPDATE, EMOJI_REACTION_REQUEST } from '../../../actions/interactions';
import { STATUS_IMPORT } from '../../../actions/importer';
import { importEmojiMutes, importEmojiMutesRevision } from '../../../actions/emoji_mutes';
import { projectStreamReaction, reactionNameHidden } from '../emoji_mute_projection';

const rules = [{
  effects: { hide_reactions: true },
  emoji: { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' },
}];

describe('emoji mute projection', () => {
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

  it('does not optimistically add a hidden unicode reaction', () => {
    const state = reducer(fromJS({ 10: { id: '10', emoji_reactions: [] } }), {
      type: EMOJI_REACTION_REQUEST,
      status: fromJS({ id: '10' }),
      name: '👍🏽',
      emojiReactionHidden: true,
    });
    expect(state.getIn(['10', 'emoji_reactions']).size).toBe(0);
  });
});
