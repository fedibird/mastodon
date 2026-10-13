import React from 'react';
import PropTypes from 'prop-types';
import { autoPlayEmoji } from 'mastodon/initial_state';

const SHORTCODE = /:([A-Za-z0-9_]{2,}):/g;

const emojiField = (emoji, camel, snake) => {
  if (!emoji) {
    return '';
  }

  if (typeof emoji.get === 'function') {
    return emoji.get(camel) || emoji.get(snake) || '';
  }

  return emoji[camel] || emoji[snake] || '';
};

const emojiList = emojis => {
  if (!emojis) {
    return [];
  }

  if (typeof emojis.toArray === 'function') {
    return emojis.toArray();
  }

  return Array.isArray(emojis) ? emojis : [];
};

class IdentityEmoji extends React.PureComponent {

  static propTypes = {
    shortcode: PropTypes.string.isRequired,
    url: PropTypes.string.isRequired,
    staticUrl: PropTypes.string,
    originalUrl: PropTypes.string,
  };

  handleClick = event => {
    event.preventDefault();
    event.stopPropagation();
  };

  render () {
    const { originalUrl, shortcode, staticUrl, url } = this.props;

    return (
      // The image sits inside the account button and must not activate that button.
      // eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions
      <img
        className='emojione custom-emoji'
        draggable='false'
        alt={`:${shortcode}:`}
        title={shortcode}
        src={url}
        data-shortcode={shortcode}
        data-original={originalUrl || url}
        data-static={staticUrl || url}
        onMouseDown={this.handleClick}
        onClick={this.handleClick}
      />
    );
  }

}

export const identityDisplayNameNodes = (name, emojis) => {
  const text = typeof name === 'string' ? name : '';
  const known = {};

  emojiList(emojis).forEach(emoji => {
    const shortcode = emojiField(emoji, 'shortcode', 'shortcode');

    if (shortcode) {
      known[shortcode] = emoji;
    }
  });

  const nodes = [];
  let last = 0;
  SHORTCODE.lastIndex = 0;
  let match = SHORTCODE.exec(text);

  while (match) {
    if (match.index > last) {
      nodes.push(text.slice(last, match.index));
    }

    const emoji = known[match[1]];

    if (emoji) {
      const originalUrl = emojiField(emoji, 'url', 'url');
      const staticUrl = emojiField(emoji, 'staticUrl', 'static_url');
      nodes.push(
        <IdentityEmoji
          key={`${match.index}:${match[1]}`}
          shortcode={match[1]}
          url={autoPlayEmoji ? (originalUrl || staticUrl) : (staticUrl || originalUrl)}
          staticUrl={staticUrl}
          originalUrl={originalUrl}
        />,
      );
    } else {
      nodes.push(match[0]);
    }

    last = match.index + match[0].length;
    match = SHORTCODE.exec(text);
  }

  if (last < text.length) {
    nodes.push(text.slice(last));
  }

  return nodes.length > 0 ? nodes : [text];
};
