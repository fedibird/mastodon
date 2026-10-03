import React from 'react';
import PropTypes from 'prop-types';
import { autoPlayEmoji } from 'mastodon/initial_state';
import { assetHost } from 'mastodon/utils/config';
import unicodeMapping from 'mastodon/features/emoji/emoji_unicode_mapping_light';
import classNames from 'classnames';

export default class Emoji extends React.PureComponent {

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
  };

  render () {
    const { emoji, hovered, url, static_url, domain, onClick, onLoad } = this.props;

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
