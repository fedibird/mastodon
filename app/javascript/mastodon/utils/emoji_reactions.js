import { List as ImmutableList } from 'immutable';

// Reaction lists can be deliberately withheld while the viewer's emoji mute
// document is loading. A missing or explicitly undefined field is not an
// empty Immutable.js List unless we normalize it at the read boundary.
export const emojiReactionsForStatus = status => {
  const reactions = status && typeof status.get === 'function' ? status.get('emoji_reactions') : null;
  return ImmutableList.isList(reactions) ? reactions : ImmutableList();
};

export const emojiReactionAccountIds = reaction => {
  const ids = reaction && typeof reaction.get === 'function' ? reaction.get('account_ids') : null;
  return ImmutableList.isList(ids) ? ids : ImmutableList();
};
