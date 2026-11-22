// The string a surface projected from. The live DOM holds the projection,
// so release must not run the rules on that projection again.
const textSources = new WeakMap();
const attributeSources = new WeakMap();

export function rememberEmojiMuteTextSource(node, source) {
  if (!node || typeof source !== 'string') {
    return;
  }

  textSources.set(node, source);
}

export function rememberEmojiMuteAttributeSource(element, name, source) {
  if (!element || typeof source !== 'string') {
    return;
  }

  let sources = attributeSources.get(element);

  if (!sources) {
    sources = new Map();
    attributeSources.set(element, sources);
  }

  sources.set(name, source);
}

export function logicalEmojiMuteText(node, fallback) {
  return textSources.has(node) ? textSources.get(node) : fallback;
}

export function logicalEmojiMuteAttribute(element, name, fallback) {
  const sources = attributeSources.get(element);

  if (sources && sources.has(name)) {
    return sources.get(name);
  }

  return fallback;
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

  ['title', 'aria-label', 'aria-description', 'aria-valuetext'].forEach(name => {
    if (element.hasAttribute(name)) {
      rememberEmojiMuteAttributeSource(element, name, source);
    }
  });
}

const READABLE_SOURCE_ATTRIBUTES = ['title', 'aria-label', 'aria-description', 'aria-valuetext', 'alt'];

const rememberElementSources = (original, live) => {
  READABLE_SOURCE_ATTRIBUTES.forEach(name => {
    if (original.hasAttribute(name)) {
      rememberEmojiMuteAttributeSource(live, name, original.getAttribute(name) || '');
    }
  });
};

// Walk both trees together. A paragraph that projects to nothing does not
// drop the source of the paragraph after it, and an image replaced by text
// keeps that text tied to the image alt.
const bindHtmlChildren = (original, live) => {
  const originalChildren = Array.from(original.childNodes || []);
  const liveChildren = Array.from(live.childNodes || []);
  let liveIndex = 0;

  originalChildren.forEach(child => {
    if (child.nodeType === Node.TEXT_NODE) {
      if (liveIndex < liveChildren.length && liveChildren[liveIndex].nodeType === Node.TEXT_NODE) {
        rememberEmojiMuteTextSource(liveChildren[liveIndex], child.nodeValue || '');
        liveIndex += 1;
      }

      return;
    }

    if (child.nodeType !== Node.ELEMENT_NODE) {
      return;
    }

    if (child.tagName === 'IMG' && liveIndex < liveChildren.length && liveChildren[liveIndex].nodeType === Node.TEXT_NODE) {
      rememberEmojiMuteTextSource(liveChildren[liveIndex], child.getAttribute('alt') || '');
      liveIndex += 1;
      return;
    }

    while (liveIndex < liveChildren.length && liveChildren[liveIndex].nodeType === Node.TEXT_NODE) {
      liveIndex += 1;
    }

    const next = liveChildren[liveIndex];

    if (!next || next.nodeType !== Node.ELEMENT_NODE || next.tagName !== child.tagName) {
      return;
    }

    rememberElementSources(child, next);
    bindHtmlChildren(child, next);
    liveIndex += 1;
  });
};

// Pair a stored HTML fragment with the nodes React inserted from its projection.
export function bindEmojiMuteHtmlSources(liveRoot, originalHtml) {
  if (!liveRoot) {
    return;
  }

  const template = liveRoot.ownerDocument
    ? liveRoot.ownerDocument.createElement('template')
    : document.createElement('template');

  template.innerHTML = originalHtml || '';
  bindHtmlChildren(template.content, liveRoot);
}
