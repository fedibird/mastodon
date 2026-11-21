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

const EMOJI_IDENTITY_ATTRIBUTES = [
  'src',
  'srcset',
  'data-original',
  'data-static',
  'data-shortcode',
  'data-domain',
  'data-emoji-id',
  'data-emoji-shortcode',
  'data-emoji-domain',
  'data-emoji-native',
  'data-emoji-custom-emoji-id',
  'data-emoji-reaction-url',
  'data-emoji-reaction-static-url',
  'aria-label',
];

// The node stays where React put it. URLs and identity attributes are
// removed in place so the pre-commit DOM cannot name the emoji.
const concealEmojiImage = img => {
  EMOJI_IDENTITY_ATTRIBUTES.forEach(name => img.removeAttribute(name));
  img.setAttribute('alt', UNVERIFIED_EMOJI_PLACEHOLDER);
  img.removeAttribute('title');
  img.setAttribute('hidden', '');
  img.setAttribute('aria-hidden', 'true');

  const host = img.closest('[data-emoji-reaction-url], [data-emoji-reaction-static-url], [data-emoji-shortcode], [data-emoji-domain], [data-emoji-native]');

  if (host && host !== img) {
    ['data-emoji-reaction-url', 'data-emoji-reaction-static-url', 'data-emoji-shortcode', 'data-emoji-domain', 'data-emoji-native', 'data-emoji-custom-emoji-id'].forEach(name => {
      host.removeAttribute(name);
    });
  }

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
