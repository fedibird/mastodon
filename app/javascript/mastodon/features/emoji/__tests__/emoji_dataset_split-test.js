import { createHash } from 'crypto';
import unicodeMapping from '../emoji_unicode_mapping_light';
import martData from '../emoji_mart_data_light';
import nimblePickerData from '../emoji_mart_nimble_data';

// These hashes are the JSON form of the datasets previously emitted together
// from emoji_compressed.js at fedibird aeef42b6. They lock display mapping,
// search data, and standard Nimble data without storing another full snapshot.
const sha = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');

describe('emoji dataset split', () => {
  it('keeps the display mapping, search data, and Nimble data', () => {
    expect(sha(unicodeMapping)).toBe('a0820b04ab50598f749281c7cf41149d16d9cd6d737cd8fbf9dd1bc15006ea64');
    expect(sha(martData)).toBe('b9e435be2fc30a5552d0318fde9a842948b38fad8c45049875497255f0c8532f');
    expect(sha(nimblePickerData)).toBe('4f372274717052c83d38965e57ccdad97ca2a21031e2a8e6761b9a4996c1fee8');
  });

  it('keeps ZWJ, skin tone, variation selector, shortcode-less, and irregular filenames', () => {
    expect(unicodeMapping['👩\u200d👩\u200d👦\u200d👦']).toEqual({
      shortCode: 'woman-woman-boy-boy',
      filename: '1f469-200d-1f469-200d-1f466-200d-1f466',
    });
    expect(unicodeMapping['👍🏻']).toEqual({
      shortCode: '+1',
      filename: '1f44d-1f3fb',
    });
    expect(unicodeMapping['#️⃣']).toEqual({
      shortCode: 'hash',
      filename: '23-20e3',
    });
    expect(unicodeMapping['👁\u200d🗨']).toEqual({
      filename: '1f441-200d-1f5e8',
    });
    expect(unicodeMapping['↙️']).toEqual({
      shortCode: 'arrow_lower_left',
      filename: '2199',
    });
    expect(unicodeMapping['❗']).toEqual({
      shortCode: 'exclamation',
      filename: '2757',
    });
  });

  it('keeps category order, aliases, and fist skin variations on the standard dataset', () => {
    expect(martData.categories.map(category => category.id)).toEqual([
      'people',
      'nature',
      'foods',
      'activity',
      'places',
      'objects',
      'symbols',
      'flags',
    ]);
    expect(martData.skins).toBeNull();
    expect(Object.keys(martData.short_names)).toHaveLength(61);
    expect(martData.emojis.pineapple.native).toBe('🍍');
    expect(Object.keys(nimblePickerData.emojis.fist.skin_variations)).toEqual([
      '1F3FB',
      '1F3FC',
      '1F3FD',
      '1F3FE',
      '1F3FF',
    ]);
    expect(nimblePickerData.emojis.sleuth_or_spy).toBeDefined();
  });
});
