import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import escapeTextContentForBrowser from 'escape-html';

import emojify, { buildCustomEmojiMap } from 'mastodon/features/emoji/emoji';

const CustomEmojiText = ({ text, customEmojis }) => (
  <span
    dangerouslySetInnerHTML={{
      __html: emojify(
        escapeTextContentForBrowser(text || ''),
        buildCustomEmojiMap(customEmojis),
      ),
    }}
  />
);

CustomEmojiText.propTypes = {
  text: PropTypes.string,
  customEmojis: ImmutablePropTypes.list.isRequired,
};

export default CustomEmojiText;
