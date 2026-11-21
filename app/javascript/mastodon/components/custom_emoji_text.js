import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import escapeTextContentForBrowser from 'escape-html';

import emojify, { buildCustomEmojiMap } from 'mastodon/features/emoji/emoji';
import { replaceEmojiInDisplayHtml } from 'mastodon/features/emoji/emoji_mute_text';
import { withEmojiMuteTextIndex } from 'mastodon/components/emoji_muted_html';

const CustomEmojiText = ({ text, customEmojis, emojiMuteTextIndex }) => (
  <span
    dangerouslySetInnerHTML={{
      __html: replaceEmojiInDisplayHtml(emojify(
        escapeTextContentForBrowser(text || ''),
        buildCustomEmojiMap(customEmojis),
      ), emojiMuteTextIndex),
    }}
  />
);

CustomEmojiText.propTypes = {
  text: PropTypes.string,
  customEmojis: ImmutablePropTypes.list.isRequired,
  emojiMuteTextIndex: PropTypes.object,
};

export default withEmojiMuteTextIndex(CustomEmojiText);
