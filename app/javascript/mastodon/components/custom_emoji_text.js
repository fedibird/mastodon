import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import escapeTextContentForBrowser from 'escape-html';

import emojify, { buildCustomEmojiMap } from 'mastodon/features/emoji/emoji';
import { replaceEmojiInDisplayHtml } from 'mastodon/features/emoji/emoji_mute_text';
import { bindEmojiMuteHtmlSources } from 'mastodon/features/emoji/emoji_mute_sources';
import { withEmojiMuteTextIndex } from 'mastodon/components/emoji_muted_html';

// The live nodes are paired with the original HTML. A text node keeps only
// the images that were replaced into it. An image that is still showing
// stays on that image.
class CustomEmojiText extends React.PureComponent {

  static propTypes = {
    text: PropTypes.string,
    customEmojis: ImmutablePropTypes.list.isRequired,
    emojiMuteTextIndex: PropTypes.object,
  };

  componentDidMount () {
    this.bindSource();
  }

  componentDidUpdate () {
    this.bindSource();
  }

  originalHtml () {
    return emojify(
      escapeTextContentForBrowser(this.props.text || ''),
      buildCustomEmojiMap(this.props.customEmojis),
    );
  }

  bindSource () {
    const root = this.node;

    if (!root) {
      return;
    }

    bindEmojiMuteHtmlSources(root, this.originalHtml());
  }

  setRef = node => {
    this.node = node;
  }

  render () {
    return (
      <span
        ref={this.setRef}
        dangerouslySetInnerHTML={{
          __html: replaceEmojiInDisplayHtml(this.originalHtml(), this.props.emojiMuteTextIndex),
        }}
      />
    );
  }

}

export default withEmojiMuteTextIndex(CustomEmojiText);
