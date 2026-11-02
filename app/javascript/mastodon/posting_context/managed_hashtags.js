// Semantic comparison for managed hashtags. NFKC plus case folding, not the
// visible spelling. This is an internal Composer helper, not ActivityPub.
const HASHTAG_BOUNDARY = /[\/)A-Za-z0-9_]/;
const HASHTAG_TOKEN = /^[\p{L}\p{M}\p{N}\p{Pc}_][\p{L}\p{M}\p{N}\p{Pc}_·・\u200C]*/u;
const TRAILING_SEPARATOR = /[·・\u200C]+$/u;
const LETTER = /\p{L}/u;

const HASHTAG_ONLY_TOKEN = /^[#＃]([\p{L}\p{M}\p{N}\p{Pc}_][\p{L}\p{M}\p{N}\p{Pc}_·・\u200C]*)$/u;

// Only a final line made entirely of valid hashtag tokens can be moved into
// the badge run. Inline tags and lines with prose, URLs, or punctuation stay
// in the body, as required by the authored-spacing rule (#471).
const isHashtagOnlyLine = line => {
  const tokens = line.trim().split(/\s+/u);

  return tokens.length > 0 && tokens.every(token => {
    const match = token.match(HASHTAG_ONLY_TOKEN);

    return match && LETTER.test(match[1]) && !TRAILING_SEPARATOR.test(match[1]);
  });
};

// A badge-eligible authored run must have an explicit blank line before it
// (#471). Walking backwards lets us retain only the run following the
// earliest valid separator, without accidentally moving a preceding tag line
// that belongs to the body (e.g. "Hello\n#inline\n\n#tail").
const trailingHashtagRun = text => {
  const parts = text.replace(/(?:\r?\n[^\S\r\n]*)+$/u, '').split(/(\r?\n)/u);
  const tags = [];
  let candidate = null;

  for (let index = parts.length - 1; index >= 0; index -= 2) {
    const line = parts[index];

    if (isHashtagOnlyLine(line)) {
      tags.unshift(line.trim());
    } else if (index >= 2 && line.trim() === '' && tags.length > 0) {
      // Everything after this blank line is hashtag-only. A prior tag line
      // without a blank-line boundary must not join this candidate.
      candidate = {
        body: parts.slice(0, index - 1).join(''),
        tags: tags.join(' '),
      };
    } else {
      break;
    }
  }

  return candidate;
};

export function normalizeManagedHashtagName(name) {
  return String(name || '').replace(/^[#＃]+/u, '').normalize('NFKC').toLowerCase();
}

export function textContainsHashtag(text, name) {
  const normalized = normalizeManagedHashtagName(name);

  if (!normalized) {
    return false;
  }

  const source = String(text || '');
  let index = 0;

  while (index < source.length) {
    const char = source[index];
    const atBoundary = index === 0 || !HASHTAG_BOUNDARY.test(source[index - 1]);

    if ((char === '#' || char === '＃') && atBoundary) {
      const match = source.slice(index + 1).match(HASHTAG_TOKEN);

      if (match) {
        const token = match[0].replace(TRAILING_SEPARATOR, '');

        if (LETTER.test(token) && normalizeManagedHashtagName(token) === normalized) {
          return true;
        }

        index += 1 + match[0].length;
        continue;
      }
    }

    index += 1;
  }

  return false;
}

export function materializeManagedHashtags(text, hashtags) {
  const raw = text || '';
  const managed = hashtags || [];

  if (managed.length === 0) {
    return raw;
  }

  const missing = managed.filter(hashtag => {
    const name = hashtag && (hashtag.normalizedName || hashtag.name);

    return name && !textContainsHashtag(raw, name);
  });
  const suffix = missing.map(hashtag => {
    const display = String((hashtag && (hashtag.name || hashtag.normalizedName)) || '').replace(/^[#＃]+/u, '');

    return `#${display}`;
  }).join(' ');

  const authoredRun = trailingHashtagRun(raw);

  if (authoredRun) {
    // The formatter and badge extractor recognize only an explicitly
    // separated final run. Use one paragraph for both authored and managed
    // hashtags, even when the managed tag was already written by the user.
    const tags = [authoredRun.tags, suffix].filter(Boolean).join(' ');

    return authoredRun.body ? `${authoredRun.body}\n\n${tags}` : tags;
  }

  if (!suffix) {
    return raw;
  }

  const base = raw.replace(/\n+$/u, '');

  return base === '' ? suffix : `${base}\n\n${suffix}`;
}
