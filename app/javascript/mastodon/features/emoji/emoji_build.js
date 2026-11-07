/* eslint-disable import/no-commonjs --
   Build-time generator. Preval wrappers require it with CommonJS. */
// Build-time generator shared by the display, search, and Nimble preval
// modules. Do not import this file from runtime code. Babel inlines each
// wrapper's own slice, and this generator, the source JSON, and @emoji-mart
// data must not ship in a bundle.
//
// PREVAL_VERSION must match the literal `3` checked by:
// - emoji_unicode_mapping_data.js
// - emoji_mart_search_data.js
// - emoji_mart_nimble_data.js
// Bump every copy together when emoji inputs or this generator change.
// babel-loader caches each preval wrapper by that wrapper's source, so a
// builder-only edit is not picked up until those version comments change.
const PREVAL_VERSION = 3;

// This json file contains the names of the categories.
const emojiMart5LocalesData = require('@emoji-mart/data/i18n/en.json');
const emojiMart5Data = require('@emoji-mart/data/sets/15/all.json');
const { uncompress: emojiMartUncompress } = require('emoji-mart/dist/utils/data');
const _ = require('lodash');


const emojiMap = require('./emoji_map.json');
// This json file is downloaded from https://github.com/iamcal/emoji-data/
// and is used to correct the sheet coordinates since we're using that repo's sheet
const emojiSheetData = require('./emoji_sheet.json');
const { unicodeToFilename } = require('./unicode_to_filename');
const { unicodeToUnifiedName } = require('./unicode_to_unified_name');

// Grabbed from `emoji_utils` to avoid circular dependency
function unifiedToNative(unified) {
  let unicodes = unified.split('-'),
    codePoints = unicodes.map((u) => `0x${u}`);

  return String.fromCodePoint(...codePoints);
}

let data = {
  compressed: true,
  categories: emojiMart5Data.categories.map(cat => {
    return {
      ...cat,
      name: emojiMart5LocalesData.categories[cat.id],
    };
  }),
  aliases: emojiMart5Data.aliases,
  emojis: _(emojiMart5Data.emojis).values().map(emoji => {
    let skin_variations = {};
    const unified = emoji.skins[0].unified.toUpperCase();
    const emojiFromRawData = emojiSheetData.find(e => e.unified === unified);

    if (!emojiFromRawData) {
      return undefined;
    }

    if (emoji.skins.length > 1) {
      const [, ...nonDefaultSkins] = emoji.skins;
      nonDefaultSkins.forEach(skin => {
        const [matchingRawCodePoints, matchingRawEmoji] = Object.entries(emojiFromRawData.skin_variations).find((pair) => {
          const [, value] = pair;
          return value.unified.toLowerCase() === skin.unified;
        });

        if (matchingRawEmoji && matchingRawCodePoints) {
          // At the time of writing, the json from `@emoji-mart/data` doesn't have data
          // for emoji like `woman-heart-woman` with two different skin tones.
          const skinToneCode = matchingRawCodePoints.split('-')[0];
          skin_variations[skinToneCode] = {
            unified: matchingRawEmoji.unified.toUpperCase(),
            non_qualified: null,
            sheet_x: matchingRawEmoji.sheet_x,
            sheet_y: matchingRawEmoji.sheet_y,
            has_img_twitter: true,
            native: unifiedToNative(matchingRawEmoji.unified.toUpperCase()),
          };
        }
      });
    }

    return {
      a: emoji.name,
      b: unified,
      c: undefined,
      f: true,
      j: [emoji.id, ...emoji.keywords],
      k: [emojiFromRawData.sheet_x, emojiFromRawData.sheet_y],
      m: emoji.emoticons?.[0],
      l: emoji.emoticons,
      o: emoji.version,
      id: emoji.id,
      skin_variations,
      native: unifiedToNative(unified.toUpperCase()),
    };
  }).compact().keyBy(e => e.id).mapValues(e => _.omit(e, 'id')).value(),
};

if (data.compressed) {
  emojiMartUncompress(data);
}

const emojiMartData = data;

const excluded       = ['®', '©', '™'];
const skinTones      = ['🏻', '🏼', '🏽', '🏾', '🏿'];
const shortcodeMap   = {};

const shortCodesToEmojiData = {};
const emojisWithoutShortCodes = [];

Object.keys(emojiMart5Data.emojis).forEach(key => {
  let emoji = emojiMart5Data.emojis[key];

  shortcodeMap[emoji.skins[0].native] = emoji.id;
});

const stripModifiers = unicode => {
  skinTones.forEach(tone => {
    unicode = unicode.replace(tone, '');
  });

  return unicode;
};

Object.keys(emojiMap).forEach(key => {
  if (excluded.includes(key)) {
    delete emojiMap[key];
    return;
  }

  const normalizedKey = stripModifiers(key);
  let shortcode       = shortcodeMap[normalizedKey];

  if (!shortcode) {
    shortcode = shortcodeMap[normalizedKey + '\uFE0F'];
  }

  const filename = emojiMap[key];

  const filenameData = [key];

  if (unicodeToFilename(key) !== filename) {
    // filename can't be derived using unicodeToFilename
    filenameData.push(filename);
  }

  if (typeof shortcode === 'undefined') {
    emojisWithoutShortCodes.push(filenameData);
  } else {
    if (!Array.isArray(shortCodesToEmojiData[shortcode])) {
      shortCodesToEmojiData[shortcode] = [[]];
    }

    shortCodesToEmojiData[shortcode][0].push(filenameData);
  }
});

Object.keys(emojiMartData.emojis).forEach(key => {
  let emoji = emojiMartData.emojis[key];


  const { native } = emoji;
  let { short_names, search, unified } = emojiMartData.emojis[key];

  if (short_names[0] !== key) {
    throw new Error('The compressor expects the first short_code to be the ' +
      'key. It may need to be rewritten if the emoji change such that this ' +
      'is no longer the case.');
  }

  short_names = short_names.slice(1); // first short name can be inferred from the key

  const searchData = [native, short_names, search];

  if (unicodeToUnifiedName(native) !== unified) {
    // unified name can't be derived from unicodeToUnifiedName
    searchData.push(unified);
  }

  if (!Array.isArray(shortCodesToEmojiData[key])) {
    shortCodesToEmojiData[key] = [[]];
  }

  shortCodesToEmojiData[key].push(searchData);
});

// JSON.parse/stringify matches @preval's serialization. `skins` is absent from
// the current emoji-mart payload, and the round-trip preserves that as null.
const legacy = JSON.parse(JSON.stringify([
  shortCodesToEmojiData,
  emojiMartData.skins,
  emojiMartData.categories,
  emojiMartData.aliases,
  emojisWithoutShortCodes,
  emojiMartData,
]));

const [
  legacyShortCodes,
  skins,
  categories,
  aliases,
  legacyEmojisWithoutShortCodes,
  nimblePickerData,
] = legacy;

const unicodeShortCodes = {};
const searchShortCodes = {};

Object.keys(legacyShortCodes).forEach(shortCode => {
  const [filenameData, searchData] = legacyShortCodes[shortCode];

  unicodeShortCodes[shortCode] = filenameData;
  searchShortCodes[shortCode] = searchData;
});

const datasets = {
  unicodeMappingData: {
    shortCodesToEmojiData: unicodeShortCodes,
    emojisWithoutShortCodes: legacyEmojisWithoutShortCodes,
  },
  searchData: {
    shortCodesToEmojiData: searchShortCodes,
    skins,
    categories,
    aliases,
  },
  nimblePickerData,
};

function buildEmojiDatasets() {
  return datasets;
}

module.exports = {
  PREVAL_VERSION,
  buildEmojiDatasets,
};
