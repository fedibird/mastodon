import { isUserEmojiImage, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from './emoji_mute_text';

const READABLE_ATTRIBUTES = ['alt', 'title', 'aria-label', 'aria-description', 'aria-valuetext'];
const SKIP_TEXT_PARENTS = new Set(['SCRIPT', 'STYLE', 'TEXTAREA', 'INPUT', 'NOSCRIPT']);

export const emojiMuteLiveDomProbe = { scans: 0 };

export function resetEmojiMuteLiveDomProbe() {
  emojiMuteLiveDomProbe.scans = 0;
}

const rewriteAttribute = (element, name) => {
  const value = element.getAttribute(name);

  if (!value) {
    return;
  }

  const next = suppressUnicodeEmoji(value);

  if (next !== value) {
    element.setAttribute(name, next);
  }
};

// The node stays where React put it. Clearing the URL and label stops the
// glyph and the screen reader without detaching a child React still owns.
const concealEmojiImage = img => {
  img.setAttribute('alt', UNVERIFIED_EMOJI_PLACEHOLDER);
  img.removeAttribute('title');
  img.removeAttribute('src');
  img.removeAttribute('srcset');
  img.setAttribute('hidden', '');
  img.setAttribute('aria-hidden', 'true');

  const picture = img.parentElement && img.parentElement.tagName === 'PICTURE' ? img.parentElement : null;

  if (!picture) {
    return;
  }

  picture.querySelectorAll('source').forEach(source => {
    source.removeAttribute('src');
    source.removeAttribute('srcset');
  });
};

const concealText = root => {
  const owner = root.ownerDocument || document;
  const walker = owner.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  const nodes = [];
  let current = walker.nextNode();

  while (current) {
    nodes.push(current);
    current = walker.nextNode();
  }

  nodes.forEach(node => {
    const parent = node.parentElement;

    if (!parent || SKIP_TEXT_PARENTS.has(parent.tagName)) {
      return;
    }

    const next = suppressUnicodeEmoji(node.nodeValue || '');

    if (next !== node.nodeValue) {
      node.nodeValue = next;
    }
  });
};

export function scrubUnverifiedEmojiFrom(root) {
  if (!root || typeof root.querySelectorAll !== 'function') {
    return;
  }

  emojiMuteLiveDomProbe.scans += 1;
  root.querySelectorAll('img').forEach(img => {
    if (!img.isConnected || !isUserEmojiImage(img)) {
      return;
    }

    concealEmojiImage(img);
  });

  root.querySelectorAll('[alt], [title], [aria-label], [aria-description], [aria-valuetext]').forEach(element => {
    READABLE_ATTRIBUTES.forEach(name => rewriteAttribute(element, name));
  });
  concealText(root);
}

export function unverifiedEmojiRoot() {
  if (typeof document === 'undefined') {
    return null;
  }

  return document.querySelector('.emoji-mutes-privacy-portal');
}

// One walk when the viewer enters suppress. Later typing and unrelated
// Redux updates do not walk the timeline again. React replaces the nodes
// on its own commit.
export function createUnverifiedEmojiGuard() {
  let suppressing = false;

  const guard = state => {
    const suppress = !!(state && typeof state.getIn === 'function' && state.getIn(['emojiMutes', 'display']) === 'suppress');

    if (!suppress) {
      suppressing = false;
      return;
    }

    if (suppressing) {
      return;
    }

    suppressing = true;
    const root = unverifiedEmojiRoot();

    if (root) {
      scrubUnverifiedEmojiFrom(root);
    }
  };

  guard.reset = () => {
    suppressing = false;
  };

  return guard;
}
