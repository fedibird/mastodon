// @preval
// version: 3
// Bump this version together with the dataset generator when emoji data changes.

const { buildEmojiDatasets, PREVAL_VERSION } = require('./emoji_build');

if (PREVAL_VERSION !== 3) {
  throw new Error('Standard Nimble emoji data version does not match the dataset generator.');
}

module.exports = buildEmojiDatasets().nimblePickerData;
