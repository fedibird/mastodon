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

const noteAttribute = (sink, element, name, emojiImage) => {
  if (!sink) {
    return;
  }

  sink.push({
    kind: 'attribute',
    element,
    name,
    had: element.hasAttribute(name),
    value: element.getAttribute(name),
    emojiImage: !!emojiImage,
    writtenHad: null,
    writtenValue: null,
  });
};

const noteText = (sink, node) => {
  if (!sink) {
    return;
  }

  sink.push({
    kind: 'text',
    node,
    value: node.nodeValue,
    written: null,
  });
};

// Capture the value this scrub left behind. A later React commit replaces it,
// and release must not put the pre-suppress string back over that commit.
const stampScrubWrites = sink => {
  if (!sink) {
    return;
  }

  sink.forEach(record => {
    if (record.kind === 'text') {
      record.written = record.node.nodeValue;
      return;
    }

    record.writtenHad = record.element.hasAttribute(record.name);
    record.writtenValue = record.element.getAttribute(record.name);
  });
};

const attributeStillOwned = record => {
  const has = record.element.hasAttribute(record.name);

  if (!record.writtenHad) {
    return !has;
  }

  return has && record.element.getAttribute(record.name) === record.writtenValue;
};

const indexRecordedAttributes = records => {
  const byElement = new Map();

  records.forEach(record => {
    if (record.kind !== 'attribute') {
      return;
    }

    let attrs = byElement.get(record.element);

    if (!attrs) {
      attrs = new Map();
      byElement.set(record.element, attrs);
    }

    if (!attrs.has(record.name)) {
      attrs.set(record.name, record);
    }
  });

  return byElement;
};

const recordedValue = (byElement, element, name) => {
  const attrs = byElement.get(element);
  const found = attrs && attrs.get(name);

  return found && found.had ? found.value : '';
};

// Identity comes from the snapshot. The live host has already lost these
// attributes, and reactionNameHidden cannot see a local custom id.
const reactionHostHidden = (byElement, host, rules) => {
  if (!host) {
    return false;
  }

  return storedReactionHidden({
    custom_emoji_id: recordedValue(byElement, host, 'data-emoji-custom-emoji-id'),
    domain: recordedValue(byElement, host, 'data-emoji-reaction-domain') || recordedValue(byElement, host, 'data-emoji-domain'),
    name: recordedValue(byElement, host, 'data-emoji-reaction-name') || recordedValue(byElement, host, 'data-emoji-shortcode') || recordedValue(byElement, host, 'data-emoji-native'),
  }, rules);
};

const writeRecordedAttribute = (record, index, raw) => {
  const { element, name, had, value } = record;

  if (!element.isConnected || !attributeStillOwned(record)) {
    return;
  }

  if (!had) {
    element.removeAttribute(name);
    return;
  }

  // Reaction glyphs follow hide_reactions. A replace_in_text rule must not
  // rewrite the alt or label that this restore puts back.
  const readable = !raw && READABLE_ATTRIBUTES.indexOf(name) !== -1;
  const next = readable ? presentEmojiMutePlain(value, index) : value;

  element.setAttribute(name, next === undefined || next === null ? value : next);
};

// The verified document, not the pre-suppress snapshot. Restoring every
// saved URL would put a newly muted glyph back on screen when React does
// not rewrite that node.
const releaseScrub = (records, state) => {
  const index = emojiMuteTextIndexFromState(state);
  const rules = state && typeof state.getIn === 'function' ? state.getIn(['emojiMutes', 'rules']) : null;
  const reactionRulesApply = state && typeof state.getIn === 'function' && state.getIn(['emojiMutes', 'display']) === 'apply';
  const recorded = indexRecordedAttributes(records);
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

      if (record.node.nodeValue !== record.written) {
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

    // Classification is from the snapshot. The live src is already gone, so
    // a classless /emoji/<hex>.svg image would otherwise look like a photo.
    if (record.emojiImage || chip) {
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
    const reactionImage = Boolean(host && host !== element);

    if ((chip || reactionImage) && reactionRulesApply && reactionHostHidden(recorded, host, rules)) {
      return;
    }

    if (chip || reactionImage) {
      bucket.forEach(record => writeRecordedAttribute(record, index, true));

      if (reactionImage) {
        keptImages.add(element);
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
      const altRecord = bucket.find(item => item.name === 'alt');

      if (projected.replacement && altRecord && attributeStillOwned(altRecord)) {
        element.setAttribute('alt', projected.replacement);
      }

      return;
    }

    bucket.forEach(record => writeRecordedAttribute(record, index));
    keptImages.add(element);

    const hiddenRecord = bucket.find(item => item.name === 'hidden');
    const ariaRecord = bucket.find(item => item.name === 'aria-hidden');

    if (hiddenRecord && !hiddenRecord.had && attributeStillOwned(hiddenRecord)) {
      element.removeAttribute('hidden');
    }

    if (ariaRecord && !ariaRecord.had && attributeStillOwned(ariaRecord)) {
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

    EMOJI_IDENTITY_ATTRIBUTES.forEach(name => noteAttribute(sink, img, name, true));
    noteAttribute(sink, img, 'alt', true);
    noteAttribute(sink, img, 'title', true);
    noteAttribute(sink, img, 'hidden', true);
    noteAttribute(sink, img, 'aria-hidden', true);
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
  stampScrubWrites(sink);
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
