const DEFAULTS = [
  '+1',
  'grinning',
  'kissing_heart',
  'heart_eyes',
  'laughing',
  'stuck_out_tongue_winking_eye',
  'sweat_smile',
  'joy',
  'yum',
  'disappointed',
  'thinking_face',
  'weary',
  'sob',
  'sunglasses',
  'heart',
  'ok_hand',
];

// Share the WebUI's order and defaults without loading its Redux selectors.
export const getFrequentlyUsedEmojiIds = (emojiCounters, limit) => {
  let emojis = emojiCounters
    .keySeq()
    .sort((a, b) => emojiCounters.get(a) - emojiCounters.get(b))
    .reverse()
    .slice(0, limit)
    .toArray();

  if (emojis.length < limit) {
    const uniqueDefaults = DEFAULTS.filter(emoji => !emojis.includes(emoji));
    emojis = emojis.concat(uniqueDefaults.slice(0, limit - emojis.length));
  }

  return emojis;
};
