import { isUserEmojiImage } from './emoji_mute_text';

// The string a surface projected from. The live DOM holds the projection,
// so release must not run the rules on that projection again.
// Attribute entries remember where the string came from. `html` is the
// original markup, which does not run plain-text rules on a photo alt.
// `plain` is a surface that already projects that text itself.
const textSources = new WeakMap();
const attributeSources = new WeakMap();

export function rememberEmojiMuteTextSource(node, source) {
  if (!node || typeof source !== 'string') {
    return;
  }

  textSources.set(node, source);
}

// The open menu and mute dialog show one projected tag. Release has to
// project that tag again from the raw name and its image identity.
export function rememberEmojiMuteHashtagSlot(node, slot) {
  if (!node || !slot || typeof slot.text !== 'string' || typeof slot.name !== 'string') {
    return;
  }

  textSources.set(node, {
    hashtagSlot: {
      text: slot.text,
      name: slot.name,
      ranges: slot.ranges || [],
      images: slot.images || [],
    },
  });
}

// Original HTML whose images this text node replaced. Plain-text projection
// cannot expand a custom shortcode, so release uses the display HTML instead.
export function rememberEmojiMuteDisplayHtml(node, html) {
  if (!node || typeof html !== 'string') {
    return;
  }

  textSources.set(node, { displayHtml: html });
}

// A flattened display name. plain is the shared string and html is the
// emojify document that carries the emoji identity. Release projects this
// pair once, so a replacement is not treated as another emoji.
export function rememberEmojiMuteDisplayName(node, plain, html) {
  if (!node || typeof plain !== 'string' || typeof html !== 'string') {
    return;
  }

  textSources.set(node, { displayName: { plain, html } });
}

export function rememberEmojiMuteAttributeSource(element, name, source, kind = 'plain') {
  if (!element || typeof source !== 'string') {
    return;
  }

  let sources = attributeSources.get(element);

  if (!sources) {
    sources = new Map();
    attributeSources.set(element, sources);
  }

  sources.set(name, { value: source, kind: kind === 'html' ? 'html' : 'plain' });
}

export function rememberEmojiMuteDisplayAttribute(element, name, plain, html) {
  if (!element || typeof plain !== 'string' || typeof html !== 'string' || html === '') {
    return;
  }

  let sources = attributeSources.get(element);

  if (!sources) {
    sources = new Map();
    attributeSources.set(element, sources);
  }

  sources.set(name, { value: plain, html, kind: 'display' });
}

export function forgetEmojiMuteAttributeSource(element, name) {
  const sources = element && attributeSources.get(element);

  if (sources) {
    sources.delete(name);
  }
}

export function logicalEmojiMuteText(node, fallback) {
  return textSources.has(node) ? textSources.get(node) : fallback;
}

const storedAttribute = (element, name) => {
  const sources = element && attributeSources.get(element);

  if (!sources || !sources.has(name)) {
    return null;
  }

  return sources.get(name);
};

export function logicalEmojiMuteAttribute(element, name, fallback) {
  const stored = storedAttribute(element, name);

  if (stored && typeof stored.value === 'string') {
    return stored.value;
  }

  return fallback;
}

export function emojiMuteAttributeSourceKind(element, name) {
  const stored = storedAttribute(element, name);

  if (!stored) {
    return null;
  }

  if (stored.kind === 'html' || stored.kind === 'display') {
    return stored.kind;
  }

  return 'plain';
}

export function emojiMuteAttributeDisplayHtml(element, name) {
  const stored = storedAttribute(element, name);

  return stored && typeof stored.html === 'string' ? stored.html : null;
}

export function hasEmojiMuteAttributeSource(element, name) {
  const sources = element && attributeSources.get(element);

  return !!(sources && sources.has(name));
}

const textNodesIn = root => {
  const nodes = [];

  if (!root) {
    return nodes;
  }

  const owner = root.ownerDocument || document;
  const walker = owner.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  let current = walker.nextNode();

  while (current) {
    const parent = current.parentElement;

    if (!parent || (parent.tagName !== 'SCRIPT' && parent.tagName !== 'STYLE')) {
      nodes.push(current);
    }

    current = walker.nextNode();
  }

  return nodes;
};

// One text node means the element is the whole projected string.
export function bindEmojiMuteElementSource(element, source) {
  if (!element || typeof source !== 'string') {
    return;
  }

  const texts = textNodesIn(element).filter(node => (node.nodeValue || '') !== '');

  if (texts.length === 1) {
    rememberEmojiMuteTextSource(texts[0], source);
  }

  ['alt', 'title', 'aria-label', 'aria-description', 'aria-valuetext'].forEach(name => {
    if (element.hasAttribute(name)) {
      rememberEmojiMuteAttributeSource(element, name, source);
    }
  });
}

const READABLE_SOURCE_ATTRIBUTES = ['title', 'aria-label', 'aria-description', 'aria-valuetext', 'alt'];

const rememberElementSources = (original, live, readableKind) => {
  const photo = live && live.tagName === 'IMG' && !isUserEmojiImage(live);
  const kind = readableKind === 'plain' && !photo ? 'plain' : 'html';

  READABLE_SOURCE_ATTRIBUTES.forEach(name => {
    if (original.hasAttribute(name)) {
      rememberEmojiMuteAttributeSource(live, name, original.getAttribute(name) || '', kind);
    }
  });
};

const isTextOrEmojiImage = node => node && (
  node.nodeType === Node.TEXT_NODE
  || (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'IMG')
);

const imageIdentity = node => [
  node.getAttribute('data-emoji-id') || '',
  node.getAttribute('data-domain') || '',
  node.getAttribute('data-shortcode') || '',
  node.getAttribute('src') || node.getAttribute('srcset') || '',
].join('\0');

// The live image is the same emoji that was not replaced. A photo with no
// identity is not treated as that emoji.
const sameSurvivingImage = (original, live) => {
  if (!original || !live || original.tagName !== 'IMG' || live.tagName !== 'IMG') {
    return false;
  }

  const identity = imageIdentity(original);

  return identity !== '\0\0\0' && identity === imageIdentity(live);
};

const isEmojiImage = node => !!(node && node.tagName === 'IMG' && (
  isUserEmojiImage(node)
  || node.getAttribute('data-emoji-id')
  || node.getAttribute('data-shortcode')
));

// The HTML projector replaces the whole picture when its img is a user emoji.
const replacedPicture = node => {
  if (!node || node.nodeType !== Node.ELEMENT_NODE || node.tagName !== 'PICTURE') {
    return false;
  }

  const img = node.querySelector && node.querySelector('img');

  return !!(img && isUserEmojiImage(img));
};

const sameSurvivingPicture = (original, live) => {
  if (!original || !live || original.tagName !== 'PICTURE' || live.tagName !== 'PICTURE') {
    return false;
  }

  return sameSurvivingImage(original.querySelector('img'), live.querySelector('img'));
};

const foldablePiece = node => isTextOrEmojiImage(node) || replacedPicture(node);

// Walk both trees together. A paragraph that projects to nothing does not
// drop the source of the paragraph after it. A text node keeps only the
// original text and images that folded into it. An image that is still in
// the live tree stays on that image, not inside the text source.
const bindHtmlChildren = (original, live, readableKind, textKind) => {
  const originalChildren = Array.from(original.childNodes || []);
  const liveChildren = Array.from(live.childNodes || []);
  let liveIndex = 0;
  let originalIndex = 0;

  while (originalIndex < originalChildren.length) {
    const child = originalChildren[originalIndex];
    const liveNode = liveChildren[liveIndex];

    if (sameSurvivingImage(child, liveNode)) {
      rememberElementSources(child, liveNode, readableKind);
      bindHtmlChildren(child, liveNode, readableKind, textKind);
      originalIndex += 1;
      liveIndex += 1;
      continue;
    }

    if (foldablePiece(child) && liveNode && liveNode.nodeType === Node.TEXT_NODE) {
      const fragment = child.ownerDocument.createElement('div');

      while (originalIndex < originalChildren.length && foldablePiece(originalChildren[originalIndex])) {
        const piece = originalChildren[originalIndex];
        const ahead = liveChildren[liveIndex + 1];

        if (sameSurvivingImage(piece, ahead) || sameSurvivingPicture(piece, ahead)) {
          break;
        }

        fragment.appendChild(piece.cloneNode(true));
        originalIndex += 1;
      }

      // Text-only status HTML keeps the HTML renderer. An embed that already
      // projects its text asks for plain text so the same rules apply once.
      if (!fragment.querySelector('img') && textKind === 'plain') {
        rememberEmojiMuteTextSource(liveNode, fragment.textContent || '');
      } else {
        rememberEmojiMuteDisplayHtml(liveNode, fragment.innerHTML);
      }

      liveIndex += 1;
      continue;
    }

    if (child.nodeType !== Node.ELEMENT_NODE) {
      originalIndex += 1;
      continue;
    }

    while (liveIndex < liveChildren.length && liveChildren[liveIndex].nodeType === Node.TEXT_NODE) {
      liveIndex += 1;
    }

    const next = liveChildren[liveIndex];

    // An emoji image that was removed must not lend its alt to the next
    // image. A photo has no emoji identity, so it still pairs by position.
    if (isEmojiImage(child) && next && next.tagName === 'IMG' && !sameSurvivingImage(child, next)) {
      originalIndex += 1;
      continue;
    }

    if (replacedPicture(child) && next && next.tagName === 'PICTURE' && !sameSurvivingPicture(child, next)) {
      originalIndex += 1;
      continue;
    }

    if (next && next.nodeType === Node.ELEMENT_NODE && next.tagName === child.tagName) {
      rememberElementSources(child, next, readableKind);
      bindHtmlChildren(child, next, readableKind, textKind);
      liveIndex += 1;
    }

    originalIndex += 1;
  }
};

// Pair a stored HTML fragment with the nodes React inserted from its projection.
export function bindEmojiMuteHtmlSources(liveRoot, originalHtml, options) {
  if (!liveRoot) {
    return;
  }

  const template = liveRoot.ownerDocument
    ? liveRoot.ownerDocument.createElement('template')
    : document.createElement('template');

  template.innerHTML = originalHtml || '';
  bindHtmlChildren(template.content, liveRoot, options && options.readableKind, options && options.textKind);
}
