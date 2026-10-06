// Separate a trailing hashtag run from sanitized status HTML.
// Parsing stays on an inert <template> so the fragment is not executed.

const BLOCK_TAGS = new Set(['BLOCKQUOTE', 'UL', 'OL', 'LI', 'PRE']);
const VISIBLE_EMPTY_TAGS = new Set([
  'IMG', 'VIDEO', 'AUDIO', 'CANVAS', 'SVG', 'IFRAME', 'OBJECT', 'EMBED',
  'PICTURE', 'HR', 'INPUT', 'TEXTAREA', 'BUTTON', 'SELECT',
]);
const VISIBLE_EMPTY_SELECTOR = 'img, video, audio, canvas, svg, iframe, object, embed, picture, hr, input, textarea, button, select';
// Structural elements stay closed. Inline wrappers such as small and span do not.
const STRUCTURAL_TAGS = new Set([
  'ADDRESS', 'ARTICLE', 'ASIDE', 'DD', 'DETAILS', 'DIV', 'DL', 'DT',
  'FIGCAPTION', 'FIGURE', 'FOOTER', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
  'HEADER', 'LI', 'MAIN', 'NAV', 'OL', 'P', 'PRE', 'SECTION', 'SUMMARY',
  'TABLE', 'TBODY', 'TD', 'TFOOT', 'TH', 'THEAD', 'TR', 'UL', 'BLOCKQUOTE',
  'SCRIPT', 'STYLE',
]);

function isElement(node) {
  return !!node && node.nodeType === Node.ELEMENT_NODE;
}

function isHashtagAnchor(node) {
  return isElement(node)
    && node.tagName === 'A'
    && node.classList.contains('mention')
    && node.classList.contains('hashtag');
}

function isWhitespaceText(node) {
  return !!node && node.nodeType === Node.TEXT_NODE && !/\S/.test(node.textContent || '');
}

function isLineBreak(node) {
  return isElement(node) && node.tagName === 'BR';
}

function isIgnorableNode(node) {
  return !!node && (
    node.nodeType === Node.COMMENT_NODE
    || node.nodeType === Node.PROCESSING_INSTRUCTION_NODE
  );
}

function isDisplaylessElement(node) {
  if (!isElement(node) || BLOCK_TAGS.has(node.tagName) || VISIBLE_EMPTY_TAGS.has(node.tagName)) {
    return false;
  }

  if (/\S/.test(node.textContent || '')) {
    return false;
  }

  return !node.querySelector(VISIBLE_EMPTY_SELECTOR);
}

function isInlineWrapperElement(node) {
  return isElement(node)
    && node.tagName !== 'A'
    && node.tagName !== 'BR'
    && !STRUCTURAL_TAGS.has(node.tagName)
    && !VISIBLE_EMPTY_TAGS.has(node.tagName);
}

// An inline element whose visible content is only a hashtag run. Nested
// wrappers count. Ordinary text or a visible-empty tag such as img does not.
function isTransparentHashtagWrapper(node) {
  if (!isInlineWrapperElement(node)) {
    return false;
  }

  let hashtagCount = 0;
  const children = node.childNodes;

  for (let index = 0; index < children.length; index += 1) {
    const child = children[index];

    if (isHashtagAnchor(child)) {
      hashtagCount += 1;
      continue;
    }

    if (isWhitespaceText(child) || isLineBreak(child) || isIgnorableNode(child) || isDisplaylessElement(child)) {
      continue;
    }

    if (isTransparentHashtagWrapper(child)) {
      hashtagCount += 1;
      continue;
    }

    return false;
  }

  return hashtagCount > 0;
}

function isHashtagCarrier(node) {
  return isHashtagAnchor(node) || isTransparentHashtagWrapper(node);
}

// Whitespace, breaks, comments, transparent hashtag wrappers, and other
// nodes with nothing else to show.
function isRunNode(node) {
  if (isHashtagAnchor(node) || isWhitespaceText(node) || isLineBreak(node) || isIgnorableNode(node)) {
    return true;
  }

  if (isTransparentHashtagWrapper(node)) {
    return true;
  }

  return isDisplaylessElement(node);
}

function hasVisibleContent(node) {
  if (!node) {
    return false;
  }

  const children = node.childNodes;

  for (let index = 0; index < children.length; index += 1) {
    const child = children[index];

    if (child.nodeType === Node.TEXT_NODE) {
      if (/\S/.test(child.textContent || '')) {
        return true;
      }
      continue;
    }

    if (!isElement(child) || isLineBreak(child)) {
      continue;
    }

    if (VISIBLE_EMPTY_TAGS.has(child.tagName) || hasVisibleContent(child)) {
      return true;
    }
  }

  return false;
}

function isTrailingChrome(node) {
  return isRunNode(node) && !isHashtagCarrier(node);
}

function lastMeaningfulChild(node) {
  let child = node.lastChild;

  // A wrapped hashtag run is meaningful. Skipping it would select the
  // previous paragraph and leave <p>Hello</p><small>#one</small> unsplit.
  while (child && isTrailingChrome(child)) {
    child = child.previousSibling;
  }

  return child;
}

// Same boundary as Formatter#trailing_content_container: the final paragraph,
// or the fragment root when the post does not end in a paragraph. Never walk
// into blockquote, list, or pre.
function trailingContainer(fragment) {
  const last = lastMeaningfulChild(fragment);

  if (!last) {
    return null;
  }

  if (isElement(last) && last.tagName === 'P') {
    return last;
  }

  return fragment;
}

function appendHashtagAnchors(node, into) {
  if (isHashtagAnchor(node)) {
    into.push(node);
    return;
  }

  if (!isElement(node)) {
    return;
  }

  const children = node.childNodes;

  for (let index = 0; index < children.length; index += 1) {
    appendHashtagAnchors(children[index], into);
  }
}

function collectTrailingRun(container) {
  const nodes = [];
  let hashtagCount = 0;
  let node = container.lastChild;

  while (node && isRunNode(node)) {
    if (isTransparentHashtagWrapper(node)) {
      const anchors = [];
      appendHashtagAnchors(node, anchors);
      nodes.push(node);

      for (let index = anchors.length - 1; index >= 0; index -= 1) {
        nodes.push(anchors[index]);
      }

      hashtagCount += anchors.length;
    } else {
      nodes.push(node);

      if (isHashtagAnchor(node)) {
        hashtagCount += 1;
      }
    }

    node = node.previousSibling;
  }

  if (hashtagCount === 0) {
    return null;
  }

  nodes.reverse();
  return nodes;
}

function hashtagData(anchor) {
  const text = anchor.textContent || '';

  return {
    name: text.replace(/^#/, ''),
    text,
    href: anchor.getAttribute('href'),
  };
}

function pruneTrailingChrome(node) {
  let child = node.lastChild;

  while (child && isTrailingChrome(child)) {
    const previous = child.previousSibling;
    child.remove();
    child = previous;
  }

  if (child && child.nodeType === Node.TEXT_NODE) {
    const trimmed = child.textContent.replace(/\s+$/u, '');

    if (trimmed !== child.textContent) {
      child.textContent = trimmed;
    }

    if (child.textContent === '') {
      child.remove();
    }
  }
}

function removeEmptyTrailingBlocks(fragment) {
  let child = fragment.lastChild;

  while (child && (
    isTrailingChrome(child)
    || (isElement(child) && !BLOCK_TAGS.has(child.tagName) && !hasVisibleContent(child))
  )) {
    const previous = child.previousSibling;
    child.remove();
    child = previous;
  }
}

function htmlWithoutRun(template, container, nodes) {
  nodes.forEach(node => node.remove());
  pruneTrailingChrome(container);

  if (container !== template.content && isElement(container) && container.tagName === 'P' && !hasVisibleContent(container)) {
    container.remove();
  }

  removeEmptyTrailingBlocks(template.content);

  if (!hasVisibleContent(template.content)) {
    return '';
  }

  return template.innerHTML;
}

export function splitTrailingHashtags(html) {
  if (typeof html !== 'string' || !html.includes('hashtag')) {
    return { html: typeof html === 'string' ? html : '', hashtags: [] };
  }

  const template = document.createElement('template');
  template.innerHTML = html;

  const container = trailingContainer(template.content);
  const nodes = container && collectTrailingRun(container);

  if (!nodes) {
    return { html, hashtags: [] };
  }

  return {
    html: htmlWithoutRun(template, container, nodes),
    hashtags: nodes.filter(isHashtagAnchor).map(hashtagData),
  };
}

export function normalizeHashtagName(name) {
  return (name || '').normalize('NFKC').toLowerCase();
}

function hashtagLabel(anchor) {
  const raw = (anchor.textContent || '').trim().replace(/^[#＃]/, '');

  return raw ? `#${raw}` : '';
}

// Hashtag anchors in document order. NFKC case-insensitive duplicates keep
// the first visible spelling. Parsing stays on an inert <template>.
export function collectStatusHashtags(html) {
  if (typeof html !== 'string' || !html.includes('hashtag')) {
    return [];
  }

  const template = document.createElement('template');
  template.innerHTML = html;
  const seen = new Set();
  const hashtags = [];

  template.content.querySelectorAll('a.mention.hashtag').forEach(anchor => {
    const text = hashtagLabel(anchor);
    const name = text.replace(/^#/, '');
    const key = normalizeHashtagName(name);

    if (!key || seen.has(key)) {
      return;
    }

    seen.add(key);
    hashtags.push({
      name,
      text,
      href: anchor.getAttribute('href'),
    });
  });

  return hashtags;
}

export function trailingHashtagsEqual(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) {
    return false;
  }

  return left.every((hashtag, index) => (
    normalizeHashtagName(hashtag && hashtag.name) === normalizeHashtagName(right[index] && right[index].name)
  ));
}

// Drop target trailing hashtags only when they are the same run as source.
// Otherwise return the original target string unchanged.
export function stripMatchingTrailingHashtags(sourceHashtags, targetHtml) {
  const target = splitTrailingHashtags(targetHtml);

  if (!trailingHashtagsEqual(sourceHashtags, target.hashtags)) {
    return targetHtml;
  }

  return target.html;
}
