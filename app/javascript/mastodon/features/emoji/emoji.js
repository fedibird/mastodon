import { autoPlayEmoji } from '../../initial_state';
import unicodeMapping from './emoji_unicode_mapping_light';
import { assetHost } from 'mastodon/utils/config';
import Trie from 'substring-trie';
import { List as ImmutableList } from 'immutable';
import { uniqCompact } from 'mastodon/utils/uniq';

const { toHiragana } = require('@koozaki/romaji-conv');

const trie = new Trie(Object.keys(unicodeMapping));

// Convert to file names from emojis. (For different variation selector emojis)
const emojiFilenames = (emojis) => {
  return emojis.map(v => unicodeMapping[v].filename);
};

// Emoji requiring extra borders depending on theme
const darkEmoji = emojiFilenames(['🎱', '🐜', '⚫', '🖤', '⬛', '◼️', '◾', '◼️', '✒️', '▪️', '💣', '🎳', '📷', '📸', '♣️', '🕶️', '✴️', '🔌', '💂‍♀️', '📽️', '🍳', '🦍', '💂', '🔪', '🕳️', '🕹️', '🕋', '🖊️', '🖋️', '💂‍♂️', '🎤', '🎓', '🎥', '🎼', '♠️', '🎩', '🦃', '📼', '📹', '🎮', '🐃', '🏴', '🐞', '🕺', '📱', '📲', '🚲', '🪮', '🐦‍⬛']);
const lightEmoji = emojiFilenames(['👽', '⚾', '🐔', '☁️', '💨', '🕊️', '👀', '🍥', '👻', '🐐', '❕', '❔', '⛸️', '🌩️', '🔊', '🔇', '📃', '🌧️', '🐏', '🍚', '🍙', '🐓', '🐑', '💀', '☠️', '🌨️', '🔉', '🔈', '💬', '💭', '🏐', '🏳️', '⚪', '⬜', '◽', '◻️', '▫️', '🪽', '🪿']);

const emojiFilename = (filename) => {
  const borderedEmoji = (document.body && document.body.classList.contains('theme-mastodon-light')) ? lightEmoji : darkEmoji;
  return borderedEmoji.includes(filename) ? (filename + '_border') : filename;
};

const emojifyTextNode = (node, customEmojis, domain) => {
  const VS15 = 0xFE0E;
  const VS16 = 0xFE0F;

  let str = node.textContent;

  const fragment = new DocumentFragment();
  let i = 0;

  for (;;) {
    let unicode_emoji;

    // Skip to the next potential emoji to replace (either custom emoji or custom emoji :shortcode:
    if (customEmojis === null) {
      while (i < str.length && !(unicode_emoji = trie.search(str.slice(i)))) {
        i += str.codePointAt(i) < 65536 ? 1 : 2;
      }
    } else {
      while (i < str.length && str[i] !== ':' && !(unicode_emoji = trie.search(str.slice(i)))) {
        i += str.codePointAt(i) < 65536 ? 1 : 2;
      }
    }

    // We reached the end of the string, nothing to replace
    if (i === str.length) {
      break;
    }

    let rend, replacement = '';
    if (str[i] === ':') {
      rend = str.indexOf(':', i + 1) + 1;

      // no matching ending ':', skip
      if (!rend) {
        i++;
        continue;
      }

      const shortcode = str.slice(i, rend);
      const custom_emoji = customEmojis[shortcode];

      // not a recognized shortcode, skip
      if (!custom_emoji) {
        i++;
        continue;
      }

      // now got a replacee as ':shortcode:'
      // if you want additional emoji handler, add statements below which set replacement and return true.
      const filename = autoPlayEmoji ? custom_emoji.url : custom_emoji.static_url;

      const striped_shortcode = shortcode.slice(1, -1);
      const alt = shortcode;
      const title = custom_emoji.alternate_name ?? striped_shortcode;

      replacement = document.createElement('img');
      replacement.setAttribute('draggable', 'false');
      replacement.setAttribute('class', 'emojione custom-emoji');
      replacement.setAttribute('alt', alt);
      replacement.setAttribute('title', title);
      replacement.setAttribute('src', filename);
      replacement.setAttribute('data-shortcode', striped_shortcode);
      replacement.setAttribute('data-domain', domain);
      replacement.setAttribute('data-original', custom_emoji.url);
      replacement.setAttribute('data-static', custom_emoji.static_url);
    } else { // start of an unicode emoji
      rend = i + unicode_emoji.length;

      // If the matched character was followed by VS15 (for selecting text presentation), skip it.
      if (str.codePointAt(rend - 1) !== VS16 && str.codePointAt(rend) === VS15) {
        i = rend + 1;
        continue;
      }

      const { filename, shortCode } = unicodeMapping[unicode_emoji];
      const title = shortCode ? `:${shortCode}:` : '';

      const isSystemTheme = !!document.body?.classList.contains('theme-system');

      const theme = (isSystemTheme || document.body?.classList.contains('theme-mastodon-light')) ? 'light' : 'dark';

      const imageFilename = emojiFilename(filename, theme);

      const img = document.createElement('img');
      img.setAttribute('draggable', 'false');
      img.setAttribute('class', 'emojione');
      img.setAttribute('alt', unicode_emoji);
      img.setAttribute('title', title);
      img.setAttribute('src', `${assetHost}/emoji/${imageFilename}.svg`);

      if (isSystemTheme && imageFilename !== emojiFilename(filename, 'dark')) {
        replacement = document.createElement('picture');

        const source = document.createElement('source');
        source.setAttribute('media', '(prefers-color-scheme: dark)');
        source.setAttribute('srcset', `${assetHost}/emoji/${emojiFilename(filename, 'dark')}.svg`);
        replacement.appendChild(source);
        replacement.appendChild(img);
      } else {
        replacement = img;
      }
    }

    fragment.append(document.createTextNode(str.slice(0, i)));
    fragment.append(replacement);
    str = str.slice(rend);
    i = 0;
  }

  fragment.append(document.createTextNode(str));
  node.parentElement.replaceChild(fragment, node);
};

const emojifyNode = (node, customEmojis, domain) => {
  for (const child of Array.from(node.childNodes)) {
    switch(child.nodeType) {
    case Node.TEXT_NODE:
      emojifyTextNode(child, customEmojis, domain);
      break;
    case Node.ELEMENT_NODE:
      if (!child.classList.contains('invisible'))
        emojifyNode(child, customEmojis, domain);
      break;
    }
  }
};

const emojify = (str, customEmojis = {}, domain = '') => {
  const wrapper = document.createElement('div');
  wrapper.innerHTML = str;

  if (!Object.keys(customEmojis).length)
    customEmojis = null;

  emojifyNode(wrapper, customEmojis, domain);

  return wrapper.innerHTML;
};

export default emojify;

export const buildCustomEmojiMap = customEmojis => customEmojis.reduce((map, emoji) => {
  map[`:${emoji.get('shortcode')}:`] = emoji.toJS();
  return map;
}, {});

export const buildCustomEmojis = (customEmojis) => {
  const emojis = [];

  customEmojis.forEach(emoji => {
    const shortcode = emoji.get('shortcode');
    const url       = autoPlayEmoji ? emoji.get('url') : emoji.get('static_url');
    const name      = shortcode.replace(':', '');
    const aliases   = emoji.get('aliases', null) ?? ImmutableList();
    const ruby      = emoji.get('ruby') ?? toHiragana(name);
    const category  = emoji.get('category');
    const keywords  = uniqCompact([name, ruby, category, ...aliases.toArray()]);

    emojis.push({
      id: name,
      name,
      short_names: [name],
      text: '',
      emoticons: [],
      keywords: keywords,
      imageUrl: url,
      custom: true,
      customCategory: category,
    });
  });

  return emojis;
};

export const categoriesFromEmojis = customEmojis => customEmojis.reduce((set, emoji) => set.add(emoji.get('category') ? `custom-${emoji.get('category')}` : 'custom'), new Set(['custom']));
