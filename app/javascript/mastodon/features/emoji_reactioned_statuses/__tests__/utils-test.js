jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS, Map as ImmutableMap } from 'immutable';
import {
  emojiReactionCatalogMatches,
  emojiReactionFilterLabel,
  emojiReactionFilterValue,
  emojiReactionSearchText,
  filterEmojiReactionCatalog,
  getPreferredEmojiReactionFilters,
  isPreferredEmojiReaction,
  normalizePreferredEmojiReactionFilters,
  placePreferredEmojiReactionFilter,
  sameEmojiFilters,
  togglePreferredEmojiReactionFilter,
} from '../utils';

const remote = {
  name: 'great',
  domain: 'example.com',
  custom: true,
  alternate_name: 'すごい',
  ruby: 'グレート',
  aliases: ['Awesome', 'Nice'],
};

describe('emoji reaction filter helpers', () => {
  it('builds the API filter value for unicode, local, and remote emoji', () => {
    expect(emojiReactionFilterValue({ name: '👍', domain: null, custom: false })).toBe('👍');
    expect(emojiReactionFilterValue({ name: 'great', domain: null, custom: true })).toBe('great');
    expect(emojiReactionFilterValue(remote)).toBe('great@example.com');
    expect(emojiReactionFilterValue(fromJS(remote))).toBe('great@example.com');
  });

  it('builds human labels and falls back from a saved filter value', () => {
    expect(emojiReactionFilterLabel({ name: '👍', domain: null, custom: false })).toBe('👍');
    expect(emojiReactionFilterLabel({ name: 'great', domain: null, custom: true })).toBe(':great:');
    expect(emojiReactionFilterLabel(remote)).toBe(':great:@example.com');
    expect(emojiReactionFilterLabel('great')).toBe(':great:');
    expect(emojiReactionFilterLabel('great@example.com')).toBe(':great:@example.com');
    expect(emojiReactionFilterLabel('👍')).toBe('👍');
    expect(emojiReactionFilterLabel('not a shortcode!')).toBe('not a shortcode!');
  });

  it('matches shortcode, domain, alias, and ruby without reordering the catalog', () => {
    const local = { name: 'great', domain: null, custom: true, count: 99 };
    const party = { name: '🎉', domain: null, custom: false, count: 1 };
    const items = [party, remote, local];

    expect(emojiReactionSearchText(remote)).toContain('great@example.com');
    expect(emojiReactionSearchText(remote)).toContain('すごい');
    expect(emojiReactionSearchText(remote)).toContain('グレート');
    expect(emojiReactionSearchText(remote)).toContain('awesome');

    expect(emojiReactionCatalogMatches(remote, 'GREAT')).toBe(true);
    expect(emojiReactionCatalogMatches(remote, 'Example.COM')).toBe(true);
    expect(emojiReactionCatalogMatches(remote, 'great@example.com')).toBe(true);
    expect(emojiReactionCatalogMatches(remote, 'すごい')).toBe(true);
    expect(emojiReactionCatalogMatches(remote, 'グレート')).toBe(true);
    expect(emojiReactionCatalogMatches(remote, 'awesome')).toBe(true);
    expect(emojiReactionCatalogMatches(party, '👍')).toBe(false);
    expect(emojiReactionCatalogMatches({ name: '👍', custom: false }, '👍')).toBe(true);

    expect(filterEmojiReactionCatalog(items, 'great').map(emojiReactionFilterValue)).toEqual(['great@example.com', 'great']);
    expect(filterEmojiReactionCatalog(items, '').map(emojiReactionFilterValue)).toEqual(['🎉', 'great@example.com', 'great']);
    expect(filterEmojiReactionCatalog(fromJS(items), 'awesome').map(emojiReactionFilterValue)).toEqual(['great@example.com']);
  });

  it('matches hiragana converted from a shortcode when ruby is missing and keeps catalog order', () => {
    const party = { name: '🎉', custom: false, count: 4 };
    const kore = { name: 'kore', custom: true, count: 3 };
    const achievement = {
      name: 'achievement',
      custom: true,
      domain: 'example.com',
      count: 2,
      ruby: 'たっせい',
      alternate_name: '達成',
      aliases: ['goal', 'remote-alias'],
    };
    const kokoro = { name: 'kokoro', custom: true, count: 1 };
    const items = [party, kokoro, achievement, kore];

    expect(emojiReactionCatalogMatches(kore, 'これ')).toBe(true);
    expect(emojiReactionCatalogMatches(kore, 'kore')).toBe(true);
    expect(emojiReactionSearchText(kore)).toContain('これ');
    expect(emojiReactionCatalogMatches({ name: 'kore', custom: true, ruby: 'たっせい' }, 'これ')).toBe(false);
    expect(emojiReactionCatalogMatches(achievement, 'たっせい')).toBe(true);
    expect(emojiReactionCatalogMatches(achievement, '達成')).toBe(true);
    expect(emojiReactionCatalogMatches(achievement, 'goal')).toBe(true);
    expect(emojiReactionCatalogMatches(achievement, 'remote-alias')).toBe(true);
    expect(emojiReactionCatalogMatches(achievement, 'example.com')).toBe(true);
    expect(emojiReactionCatalogMatches(achievement, 'achievement@example.com')).toBe(true);
    expect(emojiReactionCatalogMatches(fromJS(achievement), 'たっせい')).toBe(true);

    expect(filterEmojiReactionCatalog(items, 'これ').map(emojiReactionFilterValue)).toEqual(['kore']);
    expect(filterEmojiReactionCatalog(items, 'こ').map(emojiReactionFilterValue)).toEqual(['kokoro', 'kore']);
    expect(filterEmojiReactionCatalog(items, 'たっせい').map(emojiReactionFilterValue)).toEqual(['achievement@example.com']);
    expect(filterEmojiReactionCatalog(items, '').map(emojiReactionFilterValue)).toEqual(['🎉', 'kokoro', 'achievement@example.com', 'kore']);
  });

  it('treats filter order as significant', () => {
    expect(sameEmojiFilters(['🎉', '👍'], ['🎉', '👍'])).toBe(true);
    expect(sameEmojiFilters(['🎉', '👍'], ['👍', '🎉'])).toBe(false);
    expect(sameEmojiFilters(fromJS(['🎉']), ['🎉'])).toBe(true);
  });

  it('normalizes preferred emoji without dropping order', () => {
    expect(normalizePreferredEmojiReactionFilters(['🎉', '', '🎉', '👍'])).toEqual(['🎉', '👍']);
    expect(normalizePreferredEmojiReactionFilters(fromJS(['  ', 'great@example.com', 'great@example.com']))).toEqual(['great@example.com']);
    expect(normalizePreferredEmojiReactionFilters(undefined)).toEqual([]);
  });

  it('places a preferred emoji at a drop index without losing the other order', () => {
    expect(placePreferredEmojiReactionFilter(['🎉', '👍'], '❤️', 1)).toEqual(['🎉', '❤️', '👍']);
    expect(placePreferredEmojiReactionFilter(['🥳', '🎉', '👍'], '👍', 0)).toEqual(['👍', '🥳', '🎉']);
    expect(placePreferredEmojiReactionFilter(['🎉', '👍'], '❤️', 99)).toEqual(['🎉', '👍', '❤️']);
    expect(placePreferredEmojiReactionFilter(['🎉', '', '🎉'], '👍', 0)).toEqual(['👍', '🎉']);
  });

  it('toggles preferred emoji at the end and keeps the remaining order', () => {
    expect(togglePreferredEmojiReactionFilter(['🎉'], '👍')).toEqual(['🎉', '👍']);
    expect(togglePreferredEmojiReactionFilter(['🎉', '👍', 'great@example.com'], '👍')).toEqual(['🎉', 'great@example.com']);
    expect(togglePreferredEmojiReactionFilter(['🎉', '', '🎉'], '🎉')).toEqual([]);
    expect(isPreferredEmojiReaction(['🎉', '👍'], '👍')).toBe(true);
    expect(isPreferredEmojiReaction(['🎉'], '👍')).toBe(false);
  });

  it('reads a missing preferred list as empty and hides duplicates', () => {
    const missing = ImmutableMap({
      settings: ImmutableMap({
        emoji_reactioned_statuses: ImmutableMap({ emojis: fromJS(['🎉']) }),
      }),
    });
    const duplicated = fromJS({
      settings: {
        emoji_reactioned_statuses: {
          preferred_emojis: ['🎉', '', '🎉', '👍'],
        },
      },
    });

    expect(getPreferredEmojiReactionFilters(missing).toJS()).toEqual([]);
    expect(getPreferredEmojiReactionFilters(duplicated).toJS()).toEqual(['🎉', '👍']);
  });
});
