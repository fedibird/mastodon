import { isUserEmojiImage, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from './emoji_mute_text';

const READABLE_ATTRIBUTES = ['alt', 'title', 'aria-label', 'aria-description', 'aria-valuetext'];
const SKIP_TEXT_PARENTS = new Set(['SCRIPT', 'STYLE', 'TEXTAREA', 'INPUT', 'NOSCRIPT']);

const scrubReadableAttributes = root => {
  root.querySelectorAll('[alt], [title], [aria-label], [aria-description], [aria-valuetext]').forEach(element => {
    READABLE_ATTRIBUTES.forEach(name => {
      const value = element.getAttribute(name);

      if (!value) {
        return;
      }

      const next = suppressUnicodeEmoji(value);

      if (next !== value) {
        element.setAttribute(name, next);
      }
    });
  });
};

const scrubText = root => {
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

// Runs inside the Redux subscriber, before React commits the next projection.
// Input and textarea values are left alone so a compose draft survives.
export function scrubUnverifiedEmojiFrom(root) {
  if (!root || typeof root.querySelectorAll !== 'function') {
    return;
  }

  root.querySelectorAll('img').forEach(img => {
    if (!img.parentNode || !isUserEmojiImage(img)) {
      return;
    }

    const target = img.parentElement && img.parentElement.tagName === 'PICTURE' ? img.parentElement : img;
    const text = (img.ownerDocument || document).createTextNode(UNVERIFIED_EMOJI_PLACEHOLDER);

    if (target.parentNode) {
      target.parentNode.replaceChild(text, target);
    }
  });

  scrubReadableAttributes(root);
  scrubText(root);
}

export function scrubUnverifiedEmojiFromDocument() {
  if (typeof document === 'undefined' || !document.body) {
    return;
  }

  scrubUnverifiedEmojiFrom(document.body);
}
