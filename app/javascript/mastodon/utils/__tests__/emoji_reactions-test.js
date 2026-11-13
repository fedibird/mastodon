import { fromJS, List as ImmutableList } from 'immutable';

import { emojiReactionsForStatus, emojiReactionAccountIds } from '../emoji_reactions';

describe('emoji reaction reads while mute data is withheld', () => {
  it('normalizes missing, undefined and null reaction lists to empty Lists', () => {
    expect(emojiReactionsForStatus(null)).toEqual(ImmutableList());
    expect(emojiReactionsForStatus(fromJS({}))).toEqual(ImmutableList());
    expect(emojiReactionsForStatus(fromJS({ emoji_reactions: undefined }))).toEqual(ImmutableList());
    expect(emojiReactionsForStatus(fromJS({ emoji_reactions: null }))).toEqual(ImmutableList());
    expect(emojiReactionsForStatus(fromJS({ emoji_reactions: {} }))).toEqual(ImmutableList());
  });

  it('preserves valid lists and safely reads missing account ids', () => {
    const status = fromJS({ emoji_reactions: [{ name: '👍', account_ids: ['1'] }] });
    const reactions = emojiReactionsForStatus(status);

    expect(reactions.size).toBe(1);
    expect(emojiReactionAccountIds(reactions.first()).toJS()).toEqual(['1']);
    expect(emojiReactionAccountIds(fromJS({ name: '👍' }))).toEqual(ImmutableList());
    expect(emojiReactionAccountIds(fromJS({ account_ids: undefined }))).toEqual(ImmutableList());
    expect(emojiReactionAccountIds(null)).toEqual(ImmutableList());
  });
});
