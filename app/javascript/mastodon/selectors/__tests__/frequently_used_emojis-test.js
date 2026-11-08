import { Map as ImmutableMap, fromJS } from 'immutable';

import { getFrequentlyUsedEmojiIds } from 'mastodon/features/emoji/frequently_used_emojis';
import { getFrequentlyUsedEmojis } from '../index';

jest.mock('../../initial_state', () => ({ maxFrequentlyUsedEmojis: 3 }));
jest.mock('mastodon/features/emoji/emoji', () => ({
  buildCustomEmojis: () => [],
  categoriesFromEmojis: () => [],
}));

it('orders Unicode and custom IDs by saved usage and applies the requested limit without changing the counts', () => {
  const counts = ImmutableMap({ grinning: 2, wide_banner: 9, '+1': 6, wave_custom: 4 });

  expect(getFrequentlyUsedEmojiIds(counts, 3)).toEqual(['wide_banner', '+1', 'wave_custom']);
  expect(counts.toJS()).toEqual({ grinning: 2, wide_banner: 9, '+1': 6, wave_custom: 4 });
});

it('keeps the existing reverse key order for equal counts', () => {
  const counts = ImmutableMap({ '+1': 2, wave_custom: 5, wide_banner: 5 });

  expect(getFrequentlyUsedEmojiIds(counts, 3)).toEqual(['wide_banner', 'wave_custom', '+1']);
});

it('fills only the remaining places with defaults and does not duplicate used IDs', () => {
  const counts = ImmutableMap({ heart: 8, '+1': 3 });

  expect(getFrequentlyUsedEmojiIds(counts, 5)).toEqual(['heart', '+1', 'grinning', 'kissing_heart', 'heart_eyes']);
});

it('uses the existing sixteen defaults for empty history, respecting smaller limits', () => {
  const counts = ImmutableMap();

  expect(getFrequentlyUsedEmojiIds(counts, 100)).toEqual([
    '+1', 'grinning', 'kissing_heart', 'heart_eyes', 'laughing',
    'stuck_out_tongue_winking_eye', 'sweat_smile', 'joy', 'yum',
    'disappointed', 'thinking_face', 'weary', 'sob', 'sunglasses', 'heart', 'ok_hand',
  ]);
  expect(getFrequentlyUsedEmojiIds(counts, 2)).toEqual(['+1', 'grinning']);
});

it('keeps the WebUI selector on the same order and configured limit', () => {
  const state = fromJS({ settings: { frequentlyUsedEmojis: { grinning: 2, wide_banner: 9, '+1': 6, wave_custom: 4 } } });

  expect(getFrequentlyUsedEmojis(state)).toEqual(['wide_banner', '+1', 'wave_custom']);
});

it('keeps the WebUI defaults when no history has been saved', () => {
  expect(getFrequentlyUsedEmojis(fromJS({ settings: {} }))).toEqual(['+1', 'grinning', 'kissing_heart']);
});
