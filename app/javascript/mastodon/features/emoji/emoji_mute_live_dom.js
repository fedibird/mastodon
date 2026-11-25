import { storedReactionHidden } from './emoji_mute_projection';
import { emojiMuteAttributeDisplayHtml, emojiMuteAttributeEmptyFallback, emojiMuteAttributeFallbackWhenBlank, emojiMuteAttributeSourceKind, logicalEmojiMuteAttribute, logicalEmojiMuteText, rememberEmojiMuteTextSource } from './emoji_mute_sources';
import { bindHashtagMenuName, concealOpenHashtagDialogs, concealOpenHashtagMenus, hashtagMenuLabelIdentity, hashtagMenuStoredIdentity, projectConcealedHashtagText, projectHashtagLabel, replaceHashtagSlot } from './hashtag_menu_names';
import { attributeNamesIdentity, displayTextForEmojiMuteHtml, emojiMutedPlainText, emojiMuteTextIndexFromState, isUserEmojiImage, presentEmojiMutePlain, projectedEmojiImage, SUPPRESS_UNVERIFIED_INDEX, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from './emoji_mute_text';

// One selector for both the clear and the record. A host cleared here has to
// be in the snapshot, or a same-batch success cannot put it back.
const REACTION_HOST_SELECTOR = '.reactions-bar__item, .account__emoji_reaction, [data-emoji-reaction-name], [data-emoji-reaction-domain], [data-emoji-reaction-url], [data-emoji-reaction-static-url]';
const REACTION_SNAPSHOT_ATTRIBUTES = [
  'data-emoji-reaction-name',
  'data-emoji-reaction-domain',
  'data-emoji-reaction-url',
  'data-emoji-reaction-static-url',
];
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

const projectedAttribute = (element, name, next) => {
  const blank = next === '' || (emojiMuteAttributeFallbackWhenBlank(element, name) && typeof next === 'string' && next.trim() === '');

  if (!blank) {
    return next;
  }

  const fallback = emojiMuteAttributeEmptyFallback(element, name);

  return fallback === null ? next : fallback;
};

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

  const visible = element.getAttribute(name);

  sink.push({
    kind: 'attribute',
    element,
    name,
    had: element.hasAttribute(name),
    value: logicalEmojiMuteAttribute(element, name, visible),
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
    value: logicalEmojiMuteText(node, node.nodeValue),
    written: null,
  });
};

export function recordEmojiMuteText(sink, node) {
  noteText(sink, node);
}

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
// Scrub removes the attributes that REACTION_HOST_SELECTOR matches, so a
// later release has to recognize the host from the snapshot.
const recordedAsReactionHost = (byElement, element) => {
  const attrs = byElement.get(element);

  if (!attrs) {
    return false;
  }

  return REACTION_SNAPSHOT_ATTRIBUTES.some(name => {
    const record = attrs.get(name);

    return record && record.had;
  });
};

const reactionHostFor = (element, byElement) => {
  if (element.matches && element.matches(REACTION_HOST_SELECTOR)) {
    return element;
  }

  let current = element;

  while (current) {
    if (recordedAsReactionHost(byElement, current)) {
      return current;
    }

    current = current.parentElement;
  }

  return element.closest ? element.closest(REACTION_HOST_SELECTOR) : null;
};

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
  // rewrite the alt or label that this restore puts back. HTML photo alts
  // stay the original markup. A surface that projects the description itself
  // is applied once from that original string.
  const kind = emojiMuteAttributeSourceKind(element, name);
  const logical = kind ? logicalEmojiMuteAttribute(element, name, value) : value;

  if (kind === 'display') {
    const html = emojiMuteAttributeDisplayHtml(element, name) || '';
    const projected = emojiMutedPlainText(typeof logical === 'string' ? logical : '', html, index);
    const next = projectedAttribute(element, name, projected === undefined || projected === null ? '' : projected);

    element.setAttribute(name, next);
    return;
  }

  const plainImage = element.tagName === 'IMG' && !record.emojiImage && kind !== 'plain';
  const readable = !raw && READABLE_ATTRIBUTES.indexOf(name) !== -1;
  // A photo alt stays the original markup. A link label is projected once
  // from that original string, including when the binder stored it as HTML.
  const next = readable && !plainImage ? presentEmojiMutePlain(logical, index) : logical;
  const shown = projectedAttribute(element, name, next === undefined || next === null ? '' : next);

  element.setAttribute(name, shown);
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

      // The source can change while the placeholder stays the same.
      // Project the current logical value once. Display HTML is projected
      // by the same renderer as the surface. A remaining emoji image is not
      // written into the text node as its alt or shortcode.
      const source = logicalEmojiMuteText(record.node, record.value || '');

      if (source && typeof source === 'object' && source.hashtagSlot && typeof source.hashtagSlot.text === 'string') {
        const slot = source.hashtagSlot;
        const shown = projectHashtagLabel(slot.name, slot.ranges || [], index, slot.images || []);
        const label = shown !== '' ? shown : UNVERIFIED_EMOJI_PLACEHOLDER;

        record.node.nodeValue = replaceHashtagSlot(slot.text, slot.name, label);
        return;
      }

      if (source && typeof source === 'object' && source.displayName && typeof source.displayName.html === 'string') {
        const next = emojiMutedPlainText(source.displayName.plain || '', source.displayName.html, index);

        record.node.nodeValue = next === undefined || next === null ? (record.node.nodeValue || '') : next;
        return;
      }

      if (source && typeof source === 'object' && typeof source.displayHtml === 'string') {
        const displayed = displayTextForEmojiMuteHtml(source.displayHtml, index);

        if (displayed === null) {
          return;
        }

        record.node.nodeValue = displayed;
        return;
      }

      const plain = typeof source === 'string' ? source : '';
      const next = presentEmojiMutePlain(plain, index);
      record.node.nodeValue = next === undefined || next === null ? plain : next;
      return;
    }

    if (record.emojiLinkLabel || record.emojiLinkIdentity) {
      return;
    }

    if (!record.element.isConnected || record.element.tagName === 'SOURCE') {
      return;
    }

    const chip = (record.element.matches && record.element.matches(REACTION_HOST_SELECTOR))
      || recordedAsReactionHost(recorded, record.element);

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
    const host = reactionHostFor(element, recorded);
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

  // A custom-emoji link title is ASCII. Restore it only when every emoji
  // image in that link is still allowed. A muted image keeps the tooltip clear.
  records.forEach(record => {
    if ((!record.emojiLinkLabel && !record.emojiLinkIdentity) || !record.element.isConnected) {
      return;
    }

    const images = Array.from(record.element.querySelectorAll('img'));
    // concealEmojiImage already removed src, so a classless emoji no longer
    // looks like one. The keep set is the decision made for that image.
    const muted = images.some(img => {
      const recorded = records.some(item => item.emojiImage && item.element === img);

      return recorded && !keptImages.has(img);
    });

    if (muted) {
      return;
    }

    writeRecordedAttribute(record, index, !!record.emojiLinkIdentity);
  });
};

// The spoken label follows the option text. Only the slice that came from an
// image changes, even when the same shortcode was typed beside it.
const concealPollSpokenLabel = (label, textEl) => {
  if (!textEl || typeof label !== 'string') {
    return null;
  }

  const pieces = [];

  const walk = node => {
    if (!node) {
      return;
    }

    if (node.nodeType === Node.TEXT_NODE) {
      pieces.push(node.nodeValue || '');
      return;
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
      return;
    }

    if (node.tagName === 'IMG' && isUserEmojiImage(node)) {
      pieces.push({
        alt: node.getAttribute('alt') || '',
        code: node.getAttribute('data-shortcode') || '',
      });
      return;
    }

    Array.from(node.childNodes || []).forEach(walk);
  };

  walk(textEl);

  let cursor = 0;
  let out = '';

  for (let index = 0; index < pieces.length; index += 1) {
    const piece = pieces[index];

    if (typeof piece === 'string') {
      if (label.slice(cursor, cursor + piece.length) !== piece) {
        return null;
      }

      out += piece;
      cursor += piece.length;
      continue;
    }

    const forms = [];

    if (piece.alt) {
      forms.push(piece.alt);
    }

    if (piece.code) {
      const token = `:${piece.code}:`;

      if (forms.indexOf(token) === -1) {
        forms.push(token);
      }
    }

    const form = forms.find(candidate => label.slice(cursor, cursor + candidate.length) === candidate);

    if (!form) {
      return null;
    }

    out += UNVERIFIED_EMOJI_PLACEHOLDER;
    cursor += form.length;
  }

  if (cursor !== label.length) {
    return null;
  }

  return out;
};

export function scrubUnverifiedEmojiFrom(root, sink) {
  if (!root || typeof root.querySelectorAll !== 'function') {
    return;
  }

  emojiMuteLiveDomProbe.scans += 1;
  const pollLabels = new Map();

  root.querySelectorAll('img').forEach(img => {
    if (!img.isConnected || !isUserEmojiImage(img)) {
      return;
    }

    const pollText = img.closest && img.closest('.poll__option__text');
    const pollInput = pollText && pollText.parentElement && pollText.parentElement.querySelector('.poll__input');

    if (pollInput && !pollLabels.has(pollInput)) {
      pollLabels.set(pollInput, concealPollSpokenLabel(pollInput.getAttribute('aria-label') || '', pollText));
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

    const emojiLink = img.closest && img.closest('a');
    const hashtagLink = emojiLink && (
      (emojiLink.classList.contains('mention') && emojiLink.classList.contains('hashtag'))
      || emojiLink.hasAttribute('data-menu-hashtag')
      || emojiLink.hasAttribute('data-menu-hashtag-token')
    );

    if (emojiLink && emojiLink !== img && !hashtagLink) {
      const namesImage = value => attributeNamesIdentity(value, {
        alt: img.getAttribute('alt') || '',
        shortcode: img.getAttribute('data-shortcode') || '',
        domain: img.getAttribute('data-domain') || '',
      });

      ['title', 'aria-label', 'aria-description'].forEach(name => {
        const value = emojiLink.getAttribute(name);

        if (!namesImage(value) || (sink && attributeNoted(sink, emojiLink, name))) {
          return;
        }

        if (sink) {
          noteAttribute(sink, emojiLink, name);
          sink[sink.length - 1].emojiLinkLabel = true;
        }

        emojiLink.removeAttribute(name);
      });

      if (emojiLink.classList.contains('custom-emoji-url-link')) {
        ['href', 'data-shortcode', 'data-domain'].forEach(name => {
          if (!emojiLink.hasAttribute(name) || (sink && attributeNoted(sink, emojiLink, name))) {
            return;
          }

          if (sink) {
            noteAttribute(sink, emojiLink, name);
            sink[sink.length - 1].emojiLinkIdentity = true;
          }

          emojiLink.removeAttribute(name);
        });
      }
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

  pollLabels.forEach((next, input) => {
    const value = input.getAttribute('aria-label') || '';

    if (typeof next !== 'string' || next === value) {
      return;
    }

    noteAttribute(sink, input, 'aria-label');
    input.setAttribute('aria-label', next);
  });

  root.querySelectorAll('[alt], [title], [aria-label], [aria-description], [aria-valuetext]').forEach(element => {
    READABLE_ATTRIBUTES.forEach(name => {
      const displayHtml = emojiMuteAttributeDisplayHtml(element, name);

      if (typeof displayHtml === 'string') {
        const plain = logicalEmojiMuteAttribute(element, name, element.getAttribute(name) || '');
        const projected = emojiMutedPlainText(typeof plain === 'string' ? plain : '', displayHtml, SUPPRESS_UNVERIFIED_INDEX);
        const next = projectedAttribute(element, name, typeof projected === 'string' ? projected : '');
        const value = element.getAttribute(name);

        if (typeof next !== 'string' || next === value) {
          return;
        }

        noteAttribute(sink, element, name);
        element.setAttribute(name, next);
        return;
      }

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

    const source = logicalEmojiMuteText(node, null);

    if (source && typeof source === 'object' && source.displayName && typeof source.displayName.html === 'string') {
      const next = emojiMutedPlainText(source.displayName.plain || '', source.displayName.html, SUPPRESS_UNVERIFIED_INDEX);

      if (typeof next === 'string' && next !== (node.nodeValue || '')) {
        noteText(sink, node);
        node.nodeValue = next;
      }

      return;
    }

    const value = node.nodeValue || '';

    if (suppressUnicodeEmoji(value) === value) {
      return;
    }

    noteText(sink, node);
  });
  concealText(root);
  // The badge attribute still has the original name until React commits.
  // Unicode is not the only leak: an image shortcode such as party:blob:
  // is unchanged by suppressUnicodeEmoji, but the stored ranges say it
  // came from an emoji image. Clear that link in this same walk.
  root.querySelectorAll('a[data-menu-hashtag]').forEach(link => {
    concealHashtagMenuLink(sink, link);
  });
  // A translated link can have an image label and still not be a menu target.
  // The stored label identity is not a menu name.
  root.querySelectorAll('a').forEach(link => {
    if (link.hasAttribute('data-menu-hashtag') || link.hasAttribute('data-menu-hashtag-token')) {
      return;
    }

    const label = hashtagMenuLabelIdentity(link);

    if (!label || !label.imageRanges || label.imageRanges.length === 0) {
      return;
    }

    READABLE_ATTRIBUTES.forEach(attr => {
      const value = link.getAttribute(attr);

      if (!value) {
        return;
      }

      const next = projectConcealedHashtagText(value, label.name, label.imageRanges);

      if (next === value) {
        return;
      }

      noteAttribute(sink, link, attr);
      link.setAttribute(attr, next);
    });
  });
  stampScrubWrites(sink);
}

const attributeNoted = (sink, element, name) => sink.some(record => (
  record.kind === 'attribute' && record.element === element && record.name === name
));

const textNoted = (sink, node) => sink.some(record => record.kind === 'text' && record.node === node);

// One link. Image-derived slices leave the menu attribute, the readable
// labels, and the text React has not committed yet. A typed shortcode has
// no stored range, so this leaves it alone. The image URL itself is removed
// by the earlier img walk.
const concealHashtagMenuLink = (sink, link) => {
  const attributeName = link.getAttribute('data-menu-hashtag') || '';
  const identity = hashtagMenuStoredIdentity(link);
  const ranges = identity.imageRanges || [];
  const name = identity.name || attributeName;
  const labelIdentity = hashtagMenuLabelIdentity(link);
  const labelName = (labelIdentity && labelIdentity.name) || name;
  const labelRanges = (labelIdentity && labelIdentity.imageRanges) || ranges;
  const unicodeChanges = attributeName !== '' && suppressUnicodeEmoji(attributeName) !== attributeName;
  const actionConceals = ranges.length > 0 && projectHashtagLabel(name, ranges, SUPPRESS_UNVERIFIED_INDEX) !== name;
  const labelConceals = labelRanges.length > 0 && projectHashtagLabel(labelName, labelRanges, SUPPRESS_UNVERIFIED_INDEX) !== labelName;
  const imageConceals = actionConceals || labelConceals;

  if (!unicodeChanges && !imageConceals) {
    return;
  }

  if (unicodeChanges || actionConceals) {
    if (!attributeNoted(sink, link, 'data-menu-hashtag')) {
      noteAttribute(sink, link, 'data-menu-hashtag');
    }

    if (!attributeNoted(sink, link, 'data-menu-hashtag-token')) {
      noteAttribute(sink, link, 'data-menu-hashtag-token');
    }

    bindHashtagMenuName(link, name, SUPPRESS_UNVERIFIED_INDEX, ranges, labelIdentity);
    link.setAttribute('data-menu-hashtag', '');
  }

  if (!imageConceals) {
    return;
  }

  const projectionName = labelConceals ? labelName : name;
  const projectionRanges = labelConceals ? labelRanges : ranges;

  READABLE_ATTRIBUTES.forEach(attr => {
    const value = link.getAttribute(attr);

    if (!value) {
      return;
    }

    const noted = sink.find(record => record.kind === 'attribute' && record.element === link && record.name === attr);
    const base = noted ? noted.value : value;
    const next = projectConcealedHashtagText(base, projectionName, projectionRanges);

    if (next === value) {
      return;
    }

    if (!attributeNoted(sink, link, attr)) {
      noteAttribute(sink, link, attr);
    }

    link.setAttribute(attr, next);
  });

  const owner = link.ownerDocument || document;
  const walker = owner.createTreeWalker(link, NodeFilter.SHOW_TEXT, null);
  const nodes = [];
  let current = walker.nextNode();

  while (current) {
    nodes.push(current);
    current = walker.nextNode();
  }

  nodes.forEach(node => {
    const value = node.nodeValue || '';
    const noted = sink.find(record => record.kind === 'text' && record.node === node);
    const base = noted ? noted.value : value;
    const next = projectConcealedHashtagText(base, projectionName, projectionRanges, { shortcodeFallback: false });

    if (next === value) {
      return;
    }

    if (!textNoted(sink, node)) {
      noteText(sink, node);
    }

    node.nodeValue = next;
  });
};

// The raw alt description is not an attribute. A data attribute would stay
// readable while the popover text is concealed.
const altPopoverSources = new WeakMap();

export function rememberAltPopoverSource(element, source) {
  if (!element || typeof source !== 'string') {
    return;
  }

  altPopoverSources.set(element, source);

  const owner = element.ownerDocument || document;
  const walker = owner.createTreeWalker(element, NodeFilter.SHOW_TEXT, null);
  let text = walker.nextNode();

  while (text) {
    rememberEmojiMuteTextSource(text, source);
    text = walker.nextNode();
  }
}

export function concealOpenAltPopovers(sink) {
  if (typeof document === 'undefined') {
    return;
  }

  document.querySelectorAll('.media-gallery__alt__popover p').forEach(node => {
    if (node.classList.contains('media-gallery__alt__meta')) {
      return;
    }

    const raw = altPopoverSources.get(node);

    if (typeof raw !== 'string') {
      return;
    }

    const shown = presentEmojiMutePlain(raw, SUPPRESS_UNVERIFIED_INDEX);
    const owner = node.ownerDocument || document;
    const walker = owner.createTreeWalker(node, NodeFilter.SHOW_TEXT, null);
    let text = walker.nextNode();

    while (text) {
      const value = text.nodeValue || '';

      if (value !== shown) {
        rememberEmojiMuteTextSource(text, raw);
        noteText(sink, text);
        text.nodeValue = shown === undefined || shown === null ? value : shown;
      }

      text = walker.nextNode();
    }
  });
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

    // The menu portal is outside the privacy root. Conceal that menu in this
    // same turn, and stamp the text it rewrote so a same-batch success can
    // put the label back. A later React write no longer matches `written`.
    concealOpenHashtagMenus(records);
    concealOpenHashtagDialogs(records);
    concealOpenAltPopovers(records);
    stampScrubWrites(records);
  };

  guard.reset = () => {
    suppressing = false;
    records = [];
  };

  return guard;
}
