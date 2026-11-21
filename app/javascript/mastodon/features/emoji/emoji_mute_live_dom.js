import { reactionNameHidden } from './emoji_mute_projection';
import { emojiMuteTextIndexFromState, isUserEmojiImage, presentEmojiMutePlain, projectedEmojiImage, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from './emoji_mute_text';

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

  // The chip's tooltip is an ASCII :shortcode:, so the unicode rewrite leaves
  // it. Clear that label and the name/domain attributes on the same walk.
  const host = img.closest('.reactions-bar__item, [data-emoji-reaction-name], [data-emoji-reaction-url], [data-emoji-reaction-static-url], [data-emoji-shortcode], [data-emoji-domain], [data-emoji-native]');

  if (host && host !== img) {
    [
      'title',
      'aria-label',
      'data-emoji-reaction-name',
      'data-emoji-reaction-domain',
      'data-emoji-reaction-url',
      'data-emoji-reaction-static-url',
      'data-emoji-shortcode',
      'data-emoji-domain',
      'data-emoji-native',
      'data-emoji-custom-emoji-id',
    ].forEach(name => host.removeAttribute(name));
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

const noteAttribute = (sink, element, name) => {
  if (!sink) {
    return;
  }

  sink.push({
    kind: 'attribute',
    element,
    name,
    had: element.hasAttribute(name),
    value: element.getAttribute(name),
  });
};

const noteText = (sink, node) => {
  if (!sink) {
    return;
  }

  sink.push({ kind: 'text', node, value: node.nodeValue });
};

const writeRecordedAttribute = (record, index) => {
  const { element, name, had, value } = record;

  if (!element.isConnected) {
    return;
  }

  if (!had) {
    element.removeAttribute(name);
    return;
  }

  const readable = READABLE_ATTRIBUTES.indexOf(name) !== -1;
  const next = readable ? presentEmojiMutePlain(value, index) : value;

  element.setAttribute(name, next === undefined || next === null ? value : next);
};

// The verified document, not the pre-suppress snapshot. Restoring every
// saved URL would put a newly muted glyph back on screen when React does
// not rewrite that node.
const releaseScrub = (records, state) => {
  const index = emojiMuteTextIndexFromState(state);
  const rules = state && typeof state.getIn === 'function' ? state.getIn(['emojiMutes', 'rules']) : null;
  const grouped = new Map();

  records.forEach(record => {
    if (record.kind === 'text') {
      if (!record.node.isConnected) {
        return;
      }

      const parent = record.node.parentElement;

      if (parent && SKIP_TEXT_PARENTS.has(parent.tagName)) {
        return;
      }

      const next = presentEmojiMutePlain(record.value || '', index);
      record.node.nodeValue = next === undefined || next === null ? record.value : next;
      return;
    }

    if (!record.element.isConnected) {
      return;
    }

    const chip = record.element.classList && record.element.classList.contains('reactions-bar__item');

    if (isUserEmojiImage(record.element) || chip) {
      const bucket = grouped.get(record.element) || [];
      bucket.push(record);
      grouped.set(record.element, bucket);
      return;
    }

    writeRecordedAttribute(record, index);
  });

  grouped.forEach((bucket, element) => {
    if (element.classList && element.classList.contains('reactions-bar__item')) {
      const name = bucket.find(record => record.name === 'data-emoji-reaction-name');
      const domain = bucket.find(record => record.name === 'data-emoji-reaction-domain');
      const hidden = reactionNameHidden(name && name.value, (domain && domain.value) || null, rules);

      if (!hidden) {
        bucket.forEach(record => writeRecordedAttribute(record, index));
      }

      return;
    }

    const probe = element.cloneNode(false);

    bucket.forEach(record => {
      if (record.had) {
        probe.setAttribute(record.name, record.value === undefined || record.value === null ? '' : record.value);
      }
    });

    const projected = projectedEmojiImage(probe, index);

    if (!projected.keep) {
      if (projected.replacement) {
        element.setAttribute('alt', projected.replacement);
      }

      return;
    }

    bucket.forEach(record => writeRecordedAttribute(record, index));

    if (!bucket.some(record => record.name === 'hidden' && record.had)) {
      element.removeAttribute('hidden');
    }

    if (!bucket.some(record => record.name === 'aria-hidden' && record.had)) {
      element.removeAttribute('aria-hidden');
    }
  });
};

export function scrubUnverifiedEmojiFrom(root, sink) {
  if (!root || typeof root.querySelectorAll !== 'function') {
    return;
  }

  emojiMuteLiveDomProbe.scans += 1;
  root.querySelectorAll('img').forEach(img => {
    if (!img.isConnected || !isUserEmojiImage(img)) {
      return;
    }

    EMOJI_IDENTITY_ATTRIBUTES.forEach(name => noteAttribute(sink, img, name));
    noteAttribute(sink, img, 'alt');
    noteAttribute(sink, img, 'title');
    noteAttribute(sink, img, 'hidden');
    noteAttribute(sink, img, 'aria-hidden');
    const host = img.closest('.reactions-bar__item, [data-emoji-reaction-name]');

    if (host && host !== img) {
      ['title', 'aria-label', 'data-emoji-reaction-name', 'data-emoji-reaction-domain', 'data-emoji-reaction-url', 'data-emoji-reaction-static-url', 'data-emoji-shortcode', 'data-emoji-domain', 'data-emoji-native', 'data-emoji-custom-emoji-id'].forEach(name => {
        noteAttribute(sink, host, name);
      });
    }

    concealEmojiImage(img);
  });

  root.querySelectorAll('[alt], [title], [aria-label], [aria-description], [aria-valuetext]').forEach(element => {
    READABLE_ATTRIBUTES.forEach(name => {
      const value = element.getAttribute(name);

      if (!value || suppressUnicodeEmoji(value) === value) {
        return;
      }

      noteAttribute(sink, element, name);
      rewriteAttribute(element, name);
    });
  });

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

    const value = node.nodeValue || '';

    if (suppressUnicodeEmoji(value) === value) {
      return;
    }

    noteText(sink, node);
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
  let records = [];

  const guard = state => {
    const suppress = !!(state && typeof state.getIn === 'function' && state.getIn(['emojiMutes', 'display']) === 'suppress');

    if (!suppress) {
      if (suppressing && records.length) {
        releaseScrub(records, state);
      }

      suppressing = false;
      records = [];
      return;
    }

    if (suppressing) {
      return;
    }

    suppressing = true;
    records = [];
    const root = unverifiedEmojiRoot();

    if (root) {
      scrubUnverifiedEmojiFrom(root, records);
    }
  };

  guard.reset = () => {
    suppressing = false;
    records = [];
  };

  return guard;
}
