import React from 'react';
import PropTypes from 'prop-types';
import { autoPlayEmoji } from 'mastodon/initial_state';
import { assetHost } from 'mastodon/utils/config';
import unicodeMapping from 'mastodon/features/emoji/emoji_unicode_mapping_light';
import classNames from 'classnames';
import { withEmojiMuteTextIndex } from 'mastodon/components/emoji_muted_html';
import { UNVERIFIED_EMOJI_PLACEHOLDER } from 'mastodon/features/emoji/emoji_mute_text';

class Emoji extends React.PureComponent {

  static propTypes = {
    emoji: PropTypes.string.isRequired,
    className: PropTypes.string,
    hovered: PropTypes.bool.isRequired,
    url: PropTypes.string,
    static_url: PropTypes.string,
    domain: PropTypes.string,
    onClick: PropTypes.func,
    onLoad: PropTypes.func,
    alt: PropTypes.string,
    title: PropTypes.string,
    emojiMuteTextIndex: PropTypes.object,
  };

  render () {
    const { emoji, hovered, url, static_url, domain, onClick, onLoad, emojiMuteTextIndex } = this.props;

    if (emojiMuteTextIndex && emojiMuteTextIndex.suppressAll) {
      return <span className='emoji-mute-unverified' aria-hidden='true'>{UNVERIFIED_EMOJI_PLACEHOLDER}</span>;
    }

    if (unicodeMapping[emoji]) {
      const { filename, shortCode } = unicodeMapping[emoji];
      const alt = this.props.alt ?? emoji;
      const title = this.props.title ?? (shortCode ? `:${shortCode}:` : '');
      const className = classNames('emojione', this.props.className);

      return (
        <img
          draggable='false'
          className={className}
          alt={alt}
          title={title}
          src={`${assetHost}/emoji/${filename}.svg`}
          hidden={false}
          onLoad={onLoad}
        />
      );
    } else if (url || static_url) {
      const filename  = (autoPlayEmoji || hovered) && url ? url : static_url;
      const shortCode = `:${emoji}:`;
      const className = classNames('emojione custom-emoji', this.props.className, { 'clickable': onClick });
      const alt = this.props.alt ?? shortCode;
      const title = this.props.title ?? emoji;

      return (
        <img
          draggable='false'
          className={className}
          alt={alt}
          title={title}
          src={filename}
          hidden={false}
          data-shortcode={emoji}
          data-domain={domain}
          data-original={url}
          data-static={static_url}
          onClick={onClick}
          onLoad={onLoad}
        />
      );
    } else {
      return null;
    }
  }

}

export default withEmojiMuteTextIndex(Emoji);
