const LANG_TAGS = 'p, blockquote, pre, ul, ol, li, div, h1, h2, h3, h4, h5, h6';

function parseTopLevel(html) {
  const template = document.createElement('template');
  template.innerHTML = html || '';
  const nodes = [];

  template.content.childNodes.forEach(node => {
    if (node.nodeType === Node.TEXT_NODE) {
      if (node.textContent.trim()) {
        nodes.push(node);
      }
      return;
    }

    if (node.nodeType === Node.ELEMENT_NODE) {
      nodes.push(node);
    }
  });

  return nodes;
}

function signature(node) {
  return node.nodeType === Node.TEXT_NODE ? '#text' : node.tagName.toLowerCase();
}

function visibleText(node) {
  return (node.textContent || '').replace(/\s+/g, ' ').trim();
}

function visibleTextFromHtml(html) {
  const template = document.createElement('template');
  template.innerHTML = html || '';
  return visibleText(template.content);
}

function applyLang(element, lang) {
  if (!element || element.nodeType !== Node.ELEMENT_NODE) {
    return;
  }

  element.setAttribute('lang', lang);
  element.setAttribute('dir', 'auto');
  element.querySelectorAll(LANG_TAGS).forEach(child => {
    child.setAttribute('lang', lang);
    child.setAttribute('dir', 'auto');
  });
}

function serializeWithLang(node, lang) {
  if (node.nodeType === Node.TEXT_NODE) {
    const paragraph = document.createElement('p');
    paragraph.textContent = node.textContent;
    applyLang(paragraph, lang);
    return paragraph.outerHTML;
  }

  const clone = node.cloneNode(true);
  applyLang(clone, lang);
  return clone.outerHTML;
}

function fallbackHtml(html, lang) {
  const template = document.createElement('template');
  template.innerHTML = html || '';
  const wrapper = document.createElement('div');

  while (template.content.firstChild) {
    wrapper.appendChild(template.content.firstChild);
  }

  applyLang(wrapper, lang);
  return wrapper.outerHTML;
}

export function pairTranslationBlocks(sourceHtml, targetHtml, sourceLang, targetLang) {
  const sourceNodes = parseTopLevel(sourceHtml);
  const targetNodes = parseTopLevel(targetHtml);
  const sameStructure = sourceNodes.length > 0 &&
    sourceNodes.length === targetNodes.length &&
    sourceNodes.every((node, index) => signature(node) === signature(targetNodes[index]));

  if (!sameStructure) {
    return [{
      fallback: true,
      omitTarget: visibleTextFromHtml(sourceHtml) === visibleTextFromHtml(targetHtml),
      sourceHtml: fallbackHtml(sourceHtml, sourceLang),
      targetHtml: fallbackHtml(targetHtml, targetLang),
    }];
  }

  return sourceNodes.map((node, index) => {
    const target = targetNodes[index];

    return {
      fallback: false,
      omitTarget: visibleText(node) === visibleText(target),
      sourceHtml: serializeWithLang(node, sourceLang),
      targetHtml: serializeWithLang(target, targetLang),
    };
  });
}
