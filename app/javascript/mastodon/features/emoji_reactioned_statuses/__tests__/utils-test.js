jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS, Map as ImmutableMap } from 'immutable';
import unicodeMapping from '../../emoji/emoji_unicode_mapping_light';
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

  it('matches unicode emoji by Japanese readings without changing the stored value', () => {
    const party = { name: '🎉', custom: false };
    const laugh = { name: '😂', custom: false };
    const please = { name: '🙏', custom: false };
    const thumb = { name: '👍', custom: false };
    const heart = { name: '❤️', custom: false };
    const heartWithoutSelector = { name: '❤', custom: false };
    const lightThumb = { name: '👍🏻', custom: false };
    const darkThumb = { name: '👍🏿', custom: false };
    const doctor = { name: '👨\u200D⚕️', custom: false };
    const man = { name: '👨', custom: false };
    const staff = { name: '⚕️', custom: false };

    expect(emojiReactionCatalogMatches(party, 'くらっかー')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'おいわい')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'たんじょうび')).toBe(true);
    expect(emojiReactionCatalogMatches(laugh, 'ばくしょう')).toBe(true);
    expect(emojiReactionCatalogMatches(please, 'がっしょう')).toBe(true);
    expect(emojiReactionCatalogMatches(please, 'いのり')).toBe(true);
    expect(emojiReactionCatalogMatches(thumb, 'いいね')).toBe(true);
    expect(emojiReactionCatalogMatches(heart, 'はーと')).toBe(true);

    expect(emojiReactionCatalogMatches(party, 'クラッカー')).toBe(true);
    expect(emojiReactionCatalogMatches(heart, 'ハート')).toBe(true);

    expect(emojiReactionCatalogMatches(heartWithoutSelector, 'はーと')).toBe(true);
    expect(emojiReactionCatalogMatches(heart, 'ハート')).toBe(true);
    expect(emojiReactionFilterValue(heart)).toBe('❤️');
    expect(emojiReactionFilterValue(heartWithoutSelector)).toBe('❤');

    expect(emojiReactionCatalogMatches(lightThumb, 'いいね')).toBe(true);
    expect(emojiReactionCatalogMatches(darkThumb, 'さむずあっぷ')).toBe(true);
    expect(emojiReactionFilterValue(lightThumb)).toBe('👍🏻');
    expect(emojiReactionFilterValue(darkThumb)).toBe('👍🏿');

    expect(emojiReactionCatalogMatches(doctor, 'だんせいのいしゃ')).toBe(true);
    expect(emojiReactionCatalogMatches(man, 'だんせいのいしゃ')).toBe(false);
    expect(emojiReactionCatalogMatches(staff, 'だんせいのいしゃ')).toBe(false);
    expect(emojiReactionFilterValue(doctor)).toBe('👨\u200D⚕️');

    expect(filterEmojiReactionCatalog([man, party, laugh], 'かお').map(emojiReactionFilterValue)).toEqual(['👨', '😂']);
    expect(emojiReactionCatalogMatches(party, 'ばくしょう')).toBe(false);
    expect(emojiReactionCatalogMatches({ name: 'kore', custom: true, ruby: 'これ' }, 'くらっかー')).toBe(false);
  });

  it('matches unicode emoji by Emoji Mart shortcodes and English keywords without reordering', () => {
    const party = { name: '🎉', custom: false };
    const face = { name: '🥳', custom: false };
    const heart = { name: '❤️', custom: false };
    const thumb = { name: '👍', custom: false };
    const lightThumb = { name: '👍🏻', custom: false };
    const down = { name: '👎', custom: false };
    const doctor = { name: '👨\u200D⚕️', custom: false };
    const man = { name: '👨', custom: false };
    const staff = { name: '⚕️', custom: false };
    const keycap = { name: '#⃣', custom: false };
    const holding = { name: '🧑🏻\u200D🤝\u200D🧑🏻', custom: false };
    const customParty = { name: 'party', custom: true };
    const customHeart = { name: 'heart', custom: true, domain: 'example.com' };

    expect(emojiReactionCatalogMatches(party, 'tada')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'TADA')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'party')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'celebration')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'party popper')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'party_popper')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'party-popper')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'party,popper')).toBe(true);
    expect(emojiReactionCatalogMatches(party, 'party!')).toBe(false);
    expect(emojiReactionCatalogMatches(party, 'a')).toBe(false);
    expect(emojiReactionCatalogMatches({ name: '🅰️', custom: false }, 'a')).toBe(true);
    expect(emojiReactionCatalogMatches(face, 'party popper')).toBe(false);
    expect(emojiReactionFilterValue(party)).toBe('🎉');

    expect(emojiReactionCatalogMatches(heart, 'heart')).toBe(true);
    expect(emojiReactionCatalogMatches(heart, 'red heart')).toBe(true);
    expect(emojiReactionCatalogMatches(heart, 'red_heart')).toBe(true);
    expect(emojiReactionCatalogMatches(heart, 'red-heart')).toBe(true);
    expect(emojiReactionCatalogMatches(heart, 'love')).toBe(true);
    expect(emojiReactionFilterValue(heart)).toBe('❤️');

    expect(emojiReactionCatalogMatches(thumb, '+1')).toBe(true);
    expect(emojiReactionCatalogMatches(thumb, 'thumbsup')).toBe(true);
    expect(emojiReactionCatalogMatches(thumb, 'thumb')).toBe(true);
    expect(emojiReactionCatalogMatches(thumb, 'good')).toBe(true);
    expect(emojiReactionCatalogMatches(thumb, 'thumbs up')).toBe(true);
    expect(emojiReactionCatalogMatches(thumb, '-1')).toBe(false);
    expect(emojiReactionCatalogMatches(down, '-1')).toBe(true);
    expect(emojiReactionCatalogMatches(down, '-')).toBe(true);
    expect(emojiReactionCatalogMatches(down, 'thumbsdown')).toBe(true);
    expect(emojiReactionCatalogMatches(down, 'thumbs up')).toBe(false);
    expect(emojiReactionFilterValue(thumb)).toBe('👍');

    expect(emojiReactionCatalogMatches(lightThumb, 'thumb')).toBe(true);
    expect(emojiReactionCatalogMatches(lightThumb, 'good')).toBe(true);
    expect(emojiReactionCatalogMatches({ name: '👍🏿', custom: false }, 'thumbsup')).toBe(true);
    expect(emojiReactionFilterValue(lightThumb)).toBe('👍🏻');
    expect(emojiReactionFilterValue({ name: '👍🏿', custom: false })).toBe('👍🏿');

    expect(emojiReactionCatalogMatches(doctor, 'doctor')).toBe(true);
    expect(emojiReactionCatalogMatches(doctor, 'nurse')).toBe(true);
    expect(emojiReactionCatalogMatches(doctor, 'male-doctor')).toBe(true);
    expect(emojiReactionCatalogMatches(man, 'doctor')).toBe(false);
    expect(emojiReactionCatalogMatches(staff, 'doctor')).toBe(false);
    expect(emojiReactionCatalogMatches(doctor, 'medical')).toBe(false);
    expect(emojiReactionCatalogMatches(staff, 'medical')).toBe(true);
    expect(emojiReactionFilterValue(doctor)).toBe('👨\u200D⚕️');

    expect(emojiReactionCatalogMatches(keycap, 'hash')).toBe(true);
    expect(emojiReactionCatalogMatches(keycap, 'keycap')).toBe(true);
    expect(emojiReactionFilterValue(keycap)).toBe('#⃣');

    expect(emojiReactionCatalogMatches(holding, 'friendship')).toBe(true);
    expect(emojiReactionFilterValue(holding)).toBe('🧑🏻\u200D🤝\u200D🧑🏻');

    expect(filterEmojiReactionCatalog([thumb, party, heart], 'like').map(emojiReactionFilterValue)).toEqual(['👍', '❤️']);
    expect(filterEmojiReactionCatalog([face, party], 'celebration').map(emojiReactionFilterValue)).toEqual(['🥳', '🎉']);
    expect(filterEmojiReactionCatalog(Array.from({ length: 80 }, () => heart), 'love')).toHaveLength(80);

    expect(emojiReactionCatalogMatches(customParty, 'party')).toBe(true);
    expect(emojiReactionCatalogMatches(customParty, 'popper')).toBe(false);
    expect(emojiReactionCatalogMatches(customParty, 'celebration')).toBe(false);
    expect(emojiReactionCatalogMatches(customHeart, 'heart')).toBe(true);
    expect(emojiReactionCatalogMatches(customHeart, 'love')).toBe(false);
    expect(emojiReactionCatalogMatches(customHeart, 'valentines')).toBe(false);
  });

  it('does not collapse different Emoji Mart shortcodes onto one variation-stripped key', () => {
    const shortCodes = new Map();
    const conflicts = [];

    Object.keys(unicodeMapping).forEach((native) => {
      const shortCode = unicodeMapping[native] && unicodeMapping[native].shortCode;

      if (!shortCode) {
        return;
      }

      const key = native.replace(/[\uFE0E\uFE0F]/g, '');
      const existing = shortCodes.get(key);

      if (existing && existing !== shortCode) {
        conflicts.push([key, existing, shortCode]);
        return;
      }

      shortCodes.set(key, shortCode);
    });

    expect(conflicts).toEqual([]);
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
