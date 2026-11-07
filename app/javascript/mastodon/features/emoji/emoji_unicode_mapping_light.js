// A mapping of unicode strings to an object containing the filename
// (i.e. the svg filename) and a shortCode intended to be shown
// as a "title" attribute in an HTML element (aka tooltip).

const {
  shortCodesToEmojiData,
  emojisWithoutShortCodes,
} = require('./emoji_unicode_mapping_data');
const { unicodeToFilename } = require('./unicode_to_filename');

// decompress
const unicodeMapping = {};

function processEmojiMapData(emojiMapData, shortCode) {
  let [ native, filename ] = emojiMapData;
  if (!filename) {
    // filename name can be derived from unicodeToFilename
    filename = unicodeToFilename(native);
  }
  unicodeMapping[native] = {
    shortCode: shortCode,
    filename: filename,
  };
}

Object.keys(shortCodesToEmojiData).forEach((shortCode) => {
  shortCodesToEmojiData[shortCode].forEach(emojiMapData => processEmojiMapData(emojiMapData, shortCode));
});
emojisWithoutShortCodes.forEach(emojiMapData => processEmojiMapData(emojiMapData));

module.exports = unicodeMapping;
