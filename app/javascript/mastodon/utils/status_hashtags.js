// Separate a trailing hashtag run from sanitized status HTML.
// Parsing stays on an inert <template> so the fragment is not executed.

const BLOCK_TAGS = new Set(['BLOCKQUOTE', 'UL', 'OL', 'LI', 'PRE']);
const VISIBLE_EMPTY_TAGS = new Set([
  'IMG', 'VIDEO', 'AUDIO', 'CANVAS', 'SVG', 'IFRAME', 'OBJECT', 'EMBED',
  'PICTURE', 'HR', 'INPUT', 'TEXTAREA', 'BUTTON', 'SELECT',
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

  return !node.querySelector('img, video, audio, canvas, svg, iframe, object, embed, picture, hr, input, textarea, button, select');
}

// Whitespace, breaks, comments, and other nodes with nothing to show.
function isRunNode(node) {
  if (isHashtagAnchor(node) || isWhitespaceText(node) || isLineBreak(node) || isIgnorableNode(node)) {
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

function lastMeaningfulChild(node) {
  let child = node.lastChild;

  while (child && isRunNode(child) && !isHashtagAnchor(child)) {
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

function collectTrailingRun(container) {
  const nodes = [];
  let hashtagCount = 0;
  let node = container.lastChild;

  while (node && isRunNode(node)) {
    nodes.push(node);

    if (isHashtagAnchor(node)) {
      hashtagCount += 1;
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

  while (child && isRunNode(child) && !isHashtagAnchor(child)) {
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
    (isRunNode(child) && !isHashtagAnchor(child))
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
