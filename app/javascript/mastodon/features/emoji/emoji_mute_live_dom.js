import { storedReactionHidden } from './emoji_mute_projection';
import { emojiMuteTextIndexFromState, isUserEmojiImage, presentEmojiMutePlain, projectedEmojiImage, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from './emoji_mute_text';

// One selector for both the clear and the record. A host cleared here has to
// be in the snapshot, or a same-batch success cannot put it back.
const REACTION_HOST_SELECTOR = '.reactions-bar__item, [data-emoji-reaction-name], [data-emoji-reaction-url], [data-emoji-reaction-static-url], [data-emoji-shortcode], [data-emoji-domain], [data-emoji-native], [data-emoji-custom-emoji-id]';
const REACTION_HOST_ATTRIBUTES = [
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
];

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
  const host = img.closest(REACTION_HOST_SELECTOR);

  if (host && host !== img) {
    REACTION_HOST_ATTRIBUTES.forEach(name => host.removeAttribute(name));
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

const recordedValue = (records, element, name) => {
  const found = records.find(record => record.kind === 'attribute' && record.element === element && record.name === name);

  return found && found.had ? found.value : '';
};

// Identity comes from the snapshot. The live host has already lost these
// attributes, and reactionNameHidden cannot see a local custom id.
const reactionHostHidden = (records, host, rules) => {
  if (!host) {
    return false;
  }

  return storedReactionHidden({
    custom_emoji_id: recordedValue(records, host, 'data-emoji-custom-emoji-id'),
    domain: recordedValue(records, host, 'data-emoji-reaction-domain') || recordedValue(records, host, 'data-emoji-domain'),
    name: recordedValue(records, host, 'data-emoji-reaction-name') || recordedValue(records, host, 'data-emoji-shortcode') || recordedValue(records, host, 'data-emoji-native'),
  }, rules);
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

    if (!record.element.isConnected || record.element.tagName === 'SOURCE') {
      return;
    }

    const chip = record.element.matches && record.element.matches(REACTION_HOST_SELECTOR);

    if (isUserEmojiImage(record.element) || chip) {
      const bucket = grouped.get(record.element) || [];
      bucket.push(record);
      grouped.set(record.element, bucket);
      return;
    }

    writeRecordedAttribute(record, index);
  });

  const keptImages = new Set();

  grouped.forEach((bucket, element) => {
    const host = element.closest ? element.closest(REACTION_HOST_SELECTOR) : null;
    const chip = host === element;

    if (chip || (host && host !== element)) {
      if (reactionHostHidden(records, host, rules)) {
        return;
      }
    }

    if (chip) {
      bucket.forEach(record => writeRecordedAttribute(record, index));
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
    keptImages.add(element);

    if (!bucket.some(record => record.name === 'hidden' && record.had)) {
      element.removeAttribute('hidden');
    }

    if (!bucket.some(record => record.name === 'aria-hidden' && record.had)) {
      element.removeAttribute('aria-hidden');
    }
  });

  records.forEach(record => {
    if (record.kind !== 'attribute' || !record.element.isConnected || record.element.tagName !== 'SOURCE') {
      return;
    }

    const picture = record.element.parentElement;
    const img = picture && picture.tagName === 'PICTURE' ? picture.querySelector('img') : null;

    if (img && keptImages.has(img)) {
      writeRecordedAttribute(record, index);
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
    const host = img.closest(REACTION_HOST_SELECTOR);

    if (host && host !== img) {
      REACTION_HOST_ATTRIBUTES.forEach(name => noteAttribute(sink, host, name));
    }

    const picture = img.parentElement && img.parentElement.tagName === 'PICTURE' ? img.parentElement : null;

    if (picture) {
      picture.querySelectorAll('source').forEach(source => {
        noteAttribute(sink, source, 'src');
        noteAttribute(sink, source, 'srcset');
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
