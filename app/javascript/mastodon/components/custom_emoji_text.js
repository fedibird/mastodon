import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import escapeTextContentForBrowser from 'escape-html';

import emojify, { buildCustomEmojiMap } from 'mastodon/features/emoji/emoji';
import { replaceEmojiInDisplayHtml } from 'mastodon/features/emoji/emoji_mute_text';
import { bindEmojiMuteHtmlSources, rememberEmojiMuteTextSource } from 'mastodon/features/emoji/emoji_mute_sources';
import { withEmojiMuteTextIndex } from 'mastodon/components/emoji_muted_html';

// The rendered text is one projection of the original prop. Release reads
// that prop, so a replacement character is not projected a second time.
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

    const texts = [];
    const owner = root.ownerDocument || document;
    const walker = owner.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    let current = walker.nextNode();

    while (current) {
      if ((current.nodeValue || '') !== '') {
        texts.push(current);
      }

      current = walker.nextNode();
    }

    if (texts.length === 1) {
      rememberEmojiMuteTextSource(texts[0], this.props.text || '');
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
