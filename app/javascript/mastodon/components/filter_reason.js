import React from 'react';
import PropTypes from 'prop-types';

import { connect } from 'react-redux';

import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';

import * as emojiModule from 'mastodon/features/emoji/emoji';

import Emoji from './emoji';

const EMPTY_CUSTOM_EMOJIS = ImmutableList();
const EMPTY_EMOJI_MAP = {};
const emojiMapCache = new WeakMap();

// Same colon scan as Formatter#encode_custom_emojis: a known :shortcode: is
// replaced wherever it occurs, and an unrecognized token keeps both colons.
// Nodes are React text and <Emoji>, never HTML parsed from the filter title.
// The map is shared for one catalog list so each filtered placeholder does
// not call toJS() on every emoji again.
const customEmojiMap = (customEmojis) => {
  if (!customEmojis || typeof customEmojis.reduce !== 'function' || typeof customEmojis.get !== 'function') {
    return EMPTY_EMOJI_MAP;
  }

  let emojiMap = emojiMapCache.get(customEmojis);

  if (!emojiMap) {
    emojiMap = emojiModule.buildCustomEmojiMap(customEmojis);
    emojiMapCache.set(customEmojis, emojiMap);
  }

  return emojiMap;
};

const usableEmoji = (emoji) => Boolean(emoji && (emoji.url || emoji.static_url));

const titleToString = (title) => {
  if (title === null || title === undefined) {
    return '';
  }

  return String(title);
};

const titleList = (titles) => {
  if (ImmutableList.isList(titles)) {
    return titles;
  }

  if (Array.isArray(titles)) {
    return ImmutableList(titles);
  }

  return null;
};

const renderShortcodes = (text, emojiMap, titleIndex, nodes) => {
  let index = -1;
  let inside = false;
  let start = -1;
  let last = 0;

  while (index + 1 < text.length) {
    index += 1;

    if (inside && text[index] === ':') {
      inside = false;
      const shortcode = text.slice(start + 1, index);
      const emoji = emojiMap[`:${shortcode}:`];

      if (!usableEmoji(emoji)) {
        continue;
      }

      if (start > last) {
        nodes.push(text.slice(last, start));
      }

      nodes.push(
        <Emoji
          key={`${titleIndex}-${start}-${shortcode}`}
          emoji={shortcode}
          hovered={false}
          url={emoji.url}
          static_url={emoji.static_url}
          title={emoji.alternate_name ?? shortcode}
        />,
      );
      last = index + 1;
    } else if (text[index] === ':') {
      inside = true;
      start = index;
    }
  }

  if (last < text.length) {
    nodes.push(text.slice(last));
  }
};

export const FilterReason = ({ titles, customEmojis = EMPTY_CUSTOM_EMOJIS }) => {
  const list = titleList(titles);

  if (!list || list.isEmpty()) {
    return null;
  }

  const emojiMap = customEmojiMap(customEmojis);
  const nodes = [];

  list.forEach((title, titleIndex) => {
    if (titleIndex > 0) {
      nodes.push(', ');
    }

    renderShortcodes(titleToString(title), emojiMap, titleIndex, nodes);
  });

  return (
    <React.Fragment>
      {nodes}
    </React.Fragment>
  );
};

FilterReason.propTypes = {
  titles: PropTypes.oneOfType([
    PropTypes.array,
    ImmutablePropTypes.list,
  ]),
  customEmojis: ImmutablePropTypes.list,
};

const mapStateToProps = state => ({
  customEmojis: (state && typeof state.get === 'function' && state.get('custom_emojis')) || EMPTY_CUSTOM_EMOJIS,
});

export default connect(mapStateToProps)(FilterReason);
