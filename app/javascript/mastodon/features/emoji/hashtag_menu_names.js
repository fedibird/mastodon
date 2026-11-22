import { isUserEmojiImage, presentEmojiMutePlain, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from './emoji_mute_text';

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

  // " #tag " is the tag "tag". The hash can be fullwidth, and the spaces
  // before it are not part of the name or the image offsets.
  const leading = raw.match(/^\s*/);
  const leadCut = leading ? leading[0].length : 0;
  const body = raw.slice(leadCut);
  const lead = body.match(/^([#＃])\s*/);
  const mark = lead ? lead[1] : '#';
  const cut = leadCut + (lead ? lead[0].length : 0);
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

const shortcodesIn = text => text.match(/:[^:\s]+:/g) || [];

// Case and 1:1 NFKC. A fold that changes the length would move the ranges,
// so that character does not count as the same position.
const foldsToSame = (left, right) => {
  if (!left || !right || left.length !== 1 || right.length !== 1) {
    return false;
  }

  if (left === right || left.toLowerCase() === right.toLowerCase()) {
    return true;
  }

  const foldedLeft = left.normalize('NFKC');
  const foldedRight = right.normalize('NFKC');

  return foldedLeft.length === 1
    && foldedRight.length === 1
    && foldedLeft.toLowerCase() === foldedRight.toLowerCase();
};

// Every copy of the stored name, including a different casing. Ranges then
// hit only the image-derived slice inside that copy.
const alignedNameOffsets = (value, name) => {
  const offsets = [];

  if (!name || value.length < name.length) {
    return offsets;
  }

  for (let index = 0; index <= value.length - name.length; index += 1) {
    let matches = true;

    for (let cursor = 0; cursor < name.length; cursor += 1) {
      if (!foldsToSame(value[index + cursor], name[cursor])) {
        matches = false;
        break;
      }
    }

    if (!matches) {
      continue;
    }

    offsets.push(index);
  }

  return offsets;
};

const concealAlignedSegments = (value, imageRanges, offset) => {
  const ordered = imageRanges.slice().sort((left, right) => right[0] - left[0]);

  return ordered.reduce((next, [start, end]) => {
    if (start < 0 || end <= start || offset + end > next.length) {
      return next;
    }

    return `${next.slice(0, offset + start)}${UNVERIFIED_EMOJI_PLACEHOLDER}${next.slice(offset + end)}`;
  }, value);
};

// The label is not the stored name at a known offset. Hide the image
// shortcode rather than leave it readable.
const concealUnmappedSegments = (value, name, imageRanges) => {
  const segments = imageRanges.map(([start, end]) => name.slice(start, end)).filter(Boolean);
  let next = value;

  segments.forEach(segment => {
    if (next.includes(segment)) {
      next = next.split(segment).join(UNVERIFIED_EMOJI_PLACEHOLDER);
    }
  });

  if (next !== value) {
    return next;
  }

  shortcodesIn(name).forEach(code => {
    if (next.includes(code)) {
      next = next.split(code).join(UNVERIFIED_EMOJI_PLACEHOLDER);
    }
  });

  return next;
};

// Replace only the slices that came from emoji images. A typed :blob: that
// is not one of those slices stays in the string.
export function concealImageDerivedSegments(value, name, imageRanges) {
  if (typeof value !== 'string' || value === '' || typeof name !== 'string' || name === '' || !imageRanges || imageRanges.length === 0) {
    return value;
  }

  const offsets = alignedNameOffsets(value, name);

  if (offsets.length > 0) {
    const absolute = [];

    offsets.forEach(offset => {
      imageRanges.forEach(([start, end]) => {
        absolute.push([offset + start, offset + end]);
      });
    });
    absolute.sort((left, right) => left[0] - right[0] || left[1] - right[1]);

    const merged = [];

    absolute.forEach(([start, end]) => {
      const last = merged[merged.length - 1];

      if (last && start <= last[1]) {
        last[1] = Math.max(last[1], end);
        return;
      }

      merged.push([start, end]);
    });

    return merged.sort((left, right) => right[0] - left[0]).reduce((next, [start, end]) => {
      if (start < 0 || end <= start || end > next.length) {
        return next;
      }

      return `${next.slice(0, start)}${UNVERIFIED_EMOJI_PLACEHOLDER}${next.slice(end)}`;
    }, value);
  }

  // A second pass sees the placeholder already sitting in the image range.
  // Leave the typed shortcode that follows it.
  const projectedName = concealAlignedSegments(name, imageRanges, 0);

  if (projectedName !== name && alignedNameOffsets(value, projectedName).length > 0) {
    return value;
  }

  return concealUnmappedSegments(value, name, imageRanges);
}

// Image slices first, then Unicode. Doing Unicode first moves the stored
// name, and the fallback then hides a typed shortcode as well.
export function projectConcealedHashtagText(value, name, imageRanges) {
  const base = typeof value === 'string' ? value : '';

  return suppressUnicodeEmoji(concealImageDerivedSegments(base, name, imageRanges || []));
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

// The open menu is portaled to document.body, outside the privacy root.
// The controller registers a concealer; the suppress walk calls it in the
// same turn, before React commits the menu.
const hashtagMenuConcealers = new Set();
const hashtagMenuBindings = new Set();

export function registerHashtagMenuConcealer(conceal) {
  hashtagMenuConcealers.add(conceal);

  return () => hashtagMenuConcealers.delete(conceal);
}

export function concealOpenHashtagMenus() {
  hashtagMenuConcealers.forEach(conceal => conceal());
}

export function registerHashtagMenuBinding(sync) {
  hashtagMenuBindings.add(sync);

  return () => hashtagMenuBindings.delete(sync);
}

export function syncOpenHashtagMenu(link) {
  hashtagMenuBindings.forEach(sync => sync(link));
}
