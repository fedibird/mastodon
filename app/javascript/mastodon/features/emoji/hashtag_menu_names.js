import { isUserEmojiImage, presentEmojiMutePlain, replacementForCustomEmoji, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from './emoji_mute_text';

// The original name stays on the live element. A detached node can be
// collected, so an account switch does not keep the previous viewer's tags.
const namesByElement = new WeakMap();
const labelIdentities = new WeakMap();

const emptyIdentity = () => ({ name: '', imageRanges: [] });

const externalMarkFromAnchor = anchor => {
  if (!anchor || !anchor.previousSibling) {
    return '';
  }

  const visible = anchor.textContent || '';

  if (visible[0] === '#' || visible[0] === '＃') {
    return '';
  }

  const previous = anchor.previousSibling.textContent || '';
  const mark = previous[previous.length - 1];

  return mark === '#' || mark === '＃' ? mark : '';
};

// Text plus the alt of a real emoji image. A photo alt is not the tag.
// imageRanges mark shortcodes that came from those images, not typed text.
// An external hash is the separator and is not taken from an image alt.
export function hashtagIdentityFromNode(anchor, options) {
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
        segments.push({
          text: node.getAttribute('alt') || '',
          fromImage: true,
          image: {
            custom: !!(node.classList && node.classList.contains('custom-emoji')),
            id: node.getAttribute('data-emoji-id') || '',
            domain: node.getAttribute('data-domain') || '',
            shortcode: node.getAttribute('data-shortcode') || '',
          },
        });
      }
      return;
    }

    Array.from(node.childNodes).forEach(walk);
  };

  walk(anchor);

  let raw = '';
  const rawRanges = [];
  const rawImages = [];

  segments.forEach(segment => {
    const start = raw.length;

    raw += segment.text;

    if (segment.fromImage && segment.text) {
      rawRanges.push([start, raw.length]);
      rawImages.push({ ...segment.image, start, end: raw.length });
    }
  });

  // " #tag " is the tag "tag". The hash can be fullwidth, and the spaces
  // before it are not part of the name or the image offsets. A hash that
  // sits outside the anchor is not read from a keycap alt.
  const passedMark = options && options.externalMark;
  const externalMark = passedMark === '#' || passedMark === '＃' ? passedMark : externalMarkFromAnchor(anchor);
  const leading = raw.match(/^\s*/);
  const leadCut = leading ? leading[0].length : 0;
  const body = raw.slice(leadCut);
  const lead = externalMark ? null : body.match(/^([#＃])\s*/);
  const mark = externalMark || (lead ? lead[1] : '#');
  const cut = leadCut + (lead ? lead[0].length : 0);
  const trimmedEnd = raw.match(/\s*$/);
  const end = trimmedEnd ? raw.length - trimmedEnd[0].length : raw.length;
  const name = raw.slice(cut, end);
  const imageRanges = [];
  const images = [];

  const keepRange = (start, rangeEnd) => {
    const nextStart = start - cut;
    const nextEnd = rangeEnd - cut;

    if (nextEnd <= 0 || nextStart >= name.length) {
      return null;
    }

    return [Math.max(0, nextStart), Math.min(name.length, nextEnd)];
  };

  rawRanges.forEach(([start, rangeEnd]) => {
    const next = keepRange(start, rangeEnd);

    if (next) {
      imageRanges.push(next);
    }
  });

  rawImages.forEach(image => {
    const next = keepRange(image.start, image.end);

    if (!next) {
      return;
    }

    images.push({
      start: next[0],
      end: next[1],
      custom: image.custom,
      id: image.id,
      domain: image.domain,
      shortcode: image.shortcode,
    });
  });

  return { name, imageRanges, images, mark };
}

const shortcodesInsideRanges = (name, imageRanges) => {
  const found = [];
  const pattern = /:[^:\s]+:/g;
  let match = pattern.exec(name);

  while (match) {
    const start = match.index;
    const end = start + match[0].length;
    const inside = imageRanges.some(([rangeStart, rangeEnd]) => start < rangeEnd && end > rangeStart);

    if (inside && found.indexOf(match[0]) === -1) {
      found.push(match[0]);
    }

    match = pattern.exec(name);
  }

  return found;
};

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

  shortcodesInsideRanges(name, imageRanges).forEach(code => {
    if (next.includes(code)) {
      next = next.split(code).join(UNVERIFIED_EMOJI_PLACEHOLDER);
    }
  });

  return next;
};

// Replace only the slices that came from emoji images. A typed :blob: that
// is not one of those slices stays in the string.
export function concealImageDerivedSegments(value, name, imageRanges, options) {
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

  // A single text node is not the whole label. The shortcode fallback is for
  // a readable attribute that still contains the image shortcode.
  if (options && options.shortcodeFallback === false) {
    return value;
  }

  return concealUnmappedSegments(value, name, imageRanges);
}

// Image slices first, then Unicode. Doing Unicode first moves the stored
// name, and the fallback then hides a typed shortcode as well.
export function projectConcealedHashtagText(value, name, imageRanges, options) {
  const base = typeof value === 'string' ? value : '';

  return suppressUnicodeEmoji(concealImageDerivedSegments(base, name, imageRanges || [], options));
}

const projectPieces = (source, index, images) => {
  const ordered = images.slice().sort((left, right) => left.start - right.start);
  const pieces = [];
  let cursor = 0;

  ordered.forEach(image => {
    if (image.start < cursor || image.end <= image.start) {
      return;
    }

    pieces.push(presentEmojiMutePlain(source.slice(cursor, image.start), index) || '');

    if (index && index.suppressAll === true) {
      pieces.push(UNVERIFIED_EMOJI_PLACEHOLDER);
    } else {
      const replacement = replacementForCustomEmoji(image, index);

      pieces.push(replacement === undefined ? (presentEmojiMutePlain(source.slice(image.start, image.end), index) || '') : replacement);
    }

    cursor = image.end;
  });

  pieces.push(presentEmojiMutePlain(source.slice(cursor), index) || '');

  return pieces.join('');
};

export function projectHashtagLabel(name, imageRanges, index, images) {
  const source = typeof name === 'string' ? name : '';

  if (images && images.length > 0) {
    return projectPieces(source, index, images);
  }

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

const rememberLabelIdentity = (element, label) => {
  if (!element) {
    return;
  }

  if (label && label.name) {
    labelIdentities.set(element, { name: label.name, imageRanges: label.imageRanges || [] });
    return;
  }

  labelIdentities.delete(element);
};

export function hashtagMenuLabelIdentity(element) {
  if (!element) {
    return null;
  }

  return labelIdentities.get(element) || null;
}

export function bindHashtagMenuName(element, name, index, imageRanges, label) {
  const ranges = imageRanges || [];

  if (!element) {
    return hashtagMenuDomName(name, index, ranges);
  }

  rememberLabelIdentity(element, label);

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

export function concealOpenHashtagMenus(sink) {
  hashtagMenuConcealers.forEach(conceal => conceal(sink));
}

const hashtagDialogConcealers = new Set();

export function registerHashtagDialogConcealer(conceal) {
  hashtagDialogConcealers.add(conceal);

  return () => hashtagDialogConcealers.delete(conceal);
}

export function concealOpenHashtagDialogs(sink) {
  hashtagDialogConcealers.forEach(conceal => conceal(sink));
}

export function registerHashtagMenuBinding(sync) {
  hashtagMenuBindings.add(sync);

  return () => hashtagMenuBindings.delete(sync);
}

export function syncOpenHashtagMenu(link) {
  hashtagMenuBindings.forEach(sync => sync(link));
}
