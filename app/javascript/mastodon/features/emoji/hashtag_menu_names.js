import { isUserEmojiImage, presentEmojiMutePlain, UNVERIFIED_EMOJI_PLACEHOLDER } from './emoji_mute_text';

// The original name stays on the live element. A detached node can be
// collected, so an account switch does not keep the previous viewer's tags.
const namesByElement = new WeakMap();

const emptyIdentity = () => ({ name: '', imageRanges: [] });

// Text plus the alt of a real emoji image. A photo alt is not the tag.
// imageRanges mark shortcodes that came from those images, not typed text.
export function hashtagIdentityFromNode(anchor) {
  const segments = [];

  const walk = node => {
    if (!node) {
      return;
    }

    if (node.nodeType === Node.TEXT_NODE) {
      segments.push({ text: node.nodeValue || '', fromImage: false });
      return;
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
      return;
    }

    if (node.tagName === 'IMG') {
      if (isUserEmojiImage(node)) {
        segments.push({ text: node.getAttribute('alt') || '', fromImage: true });
      }
      return;
    }

    Array.from(node.childNodes).forEach(walk);
  };

  walk(anchor);

  let raw = '';
  const rawRanges = [];

  segments.forEach(segment => {
    const start = raw.length;

    raw += segment.text;

    if (segment.fromImage && segment.text) {
      rawRanges.push([start, raw.length]);
    }
  });

  const lead = raw.match(/^([#＃])\s*/);
  const mark = lead ? lead[1] : '#';
  const cut = lead ? lead[0].length : 0;
  const trimmedEnd = raw.match(/\s*$/);
  const end = trimmedEnd ? raw.length - trimmedEnd[0].length : raw.length;
  const name = raw.slice(cut, end);
  const imageRanges = [];

  rawRanges.forEach(([start, rangeEnd]) => {
    const nextStart = start - cut;
    const nextEnd = rangeEnd - cut;

    if (nextEnd <= 0 || nextStart >= name.length) {
      return;
    }

    imageRanges.push([Math.max(0, nextStart), Math.min(name.length, nextEnd)]);
  });

  return { name, imageRanges, mark };
}

export function projectHashtagLabel(name, imageRanges, index) {
  const source = typeof name === 'string' ? name : '';
  let projected = source;

  if (index && index.suppressAll === true && imageRanges && imageRanges.length > 0) {
    const ordered = imageRanges.slice().sort((left, right) => right[0] - left[0]);

    ordered.forEach(([start, end]) => {
      projected = `${projected.slice(0, start)}${UNVERIFIED_EMOJI_PLACEHOLDER}${projected.slice(end)}`;
    });
  }

  const shown = presentEmojiMutePlain(projected, index);

  return typeof shown === 'string' ? shown : projected;
}

const concealsName = (name, imageRanges, index) => {
  if (!name || !index || index.suppressAll !== true) {
    return false;
  }

  return projectHashtagLabel(name, imageRanges, index) !== name;
};

// The attribute the menu selector requires. A concealed name is an empty
// value plus data-menu-hashtag-token, never a string a real tag could share.
export function hashtagMenuDomName(name, index, imageRanges) {
  return concealsName(name, imageRanges, index) ? '' : name;
}

export function bindHashtagMenuName(element, name, index, imageRanges) {
  const ranges = imageRanges || [];

  if (!element) {
    return hashtagMenuDomName(name, index, ranges);
  }

  if (!name) {
    namesByElement.delete(element);
    element.removeAttribute('data-menu-hashtag-token');
    return '';
  }

  // Keep image ranges while the tag is verified. An open menu reads them
  // once, and still projects them after the display becomes unverified.
  if (ranges.length > 0 || concealsName(name, ranges, index)) {
    namesByElement.set(element, { name, imageRanges: ranges });
  } else {
    namesByElement.delete(element);
  }

  if (!concealsName(name, ranges, index)) {
    element.removeAttribute('data-menu-hashtag-token');
    return name;
  }

  element.setAttribute('data-menu-hashtag-token', '');

  return '';
}

export function hashtagMenuStoredIdentity(element) {
  if (!element || typeof element.getAttribute !== 'function') {
    return emptyIdentity();
  }

  const stored = namesByElement.get(element);

  if (element.hasAttribute('data-menu-hashtag-token')) {
    if (stored && typeof stored === 'object') {
      return { name: stored.name || '', imageRanges: stored.imageRanges || [] };
    }

    return { name: typeof stored === 'string' ? stored : '', imageRanges: [] };
  }

  if (stored && typeof stored === 'object' && stored.imageRanges && stored.imageRanges.length > 0) {
    return { name: stored.name || '', imageRanges: stored.imageRanges };
  }

  return { name: element.getAttribute('data-menu-hashtag') || '', imageRanges: [] };
}

// Only an element that opted into the token is resolved. A plain tag whose
// text happens to match some other token keeps that text.
export function hashtagMenuStoredName(element) {
  return hashtagMenuStoredIdentity(element).name;
}
