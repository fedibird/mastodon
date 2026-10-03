jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS } from 'immutable';
import {
  emojiReactionCatalogMatches,
  emojiReactionFilterLabel,
  emojiReactionFilterValue,
  emojiReactionSearchText,
  filterEmojiReactionCatalog,
  sameEmojiFilters,
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

  it('treats filter order as significant', () => {
    expect(sameEmojiFilters(['🎉', '👍'], ['🎉', '👍'])).toBe(true);
    expect(sameEmojiFilters(['🎉', '👍'], ['👍', '🎉'])).toBe(false);
    expect(sameEmojiFilters(fromJS(['🎉']), ['🎉'])).toBe(true);
  });
});
