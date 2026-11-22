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

// Pair a stored HTML fragment with the nodes React inserted from its projection.
// The walk stops when the trees disagree, instead of guessing a match.
export function bindEmojiMuteHtmlSources(liveRoot, originalHtml) {
  if (!liveRoot) {
    return;
  }

  const template = liveRoot.ownerDocument
    ? liveRoot.ownerDocument.createElement('template')
    : document.createElement('template');

  template.innerHTML = originalHtml || '';
  const originalTexts = textNodesIn(template.content);
  const liveTexts = textNodesIn(liveRoot);

  if (originalTexts.length === liveTexts.length) {
    originalTexts.forEach((node, index) => {
      rememberEmojiMuteTextSource(liveTexts[index], node.nodeValue || '');
    });
  }

  const readable = ['title', 'aria-label', 'aria-description', 'aria-valuetext', 'alt'];
  const originalElements = Array.from(template.content.querySelectorAll(readable.map(name => `[${name}]`).join(',')));
  const liveElements = Array.from(liveRoot.querySelectorAll(readable.map(name => `[${name}]`).join(',')));

  if (originalElements.length !== liveElements.length) {
    return;
  }

  originalElements.forEach((element, index) => {
    const live = liveElements[index];

    if (!live || live.tagName !== element.tagName) {
      return;
    }

    readable.forEach(name => {
      if (element.hasAttribute(name)) {
        rememberEmojiMuteAttributeSource(live, name, element.getAttribute(name) || '');
      }
    });
  });
}
