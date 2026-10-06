// Semantic comparison for managed hashtags. NFKC plus case folding, not the
// visible spelling. This is an internal Composer helper, not ActivityPub.
const HASHTAG_BOUNDARY = /[\/)A-Za-z0-9_]/;
const HASHTAG_TOKEN = /^[\p{L}\p{M}\p{N}\p{Pc}_][\p{L}\p{M}\p{N}\p{Pc}_·・\u00B7\u200C]*/u;
const TRAILING_SEPARATOR = /[·・\u00B7\u200C_]+$/u;
const LETTER = /\p{L}/u;

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
  const missing = (hashtags || []).filter(hashtag => {
    const name = hashtag && (hashtag.normalizedName || hashtag.name);

    return name && !textContainsHashtag(raw, name);
  });

  if (missing.length === 0) {
    return raw;
  }

  const suffix = missing.map(hashtag => {
    const display = String((hashtag && (hashtag.name || hashtag.normalizedName)) || '').replace(/^[#＃]+/u, '');

    return `#${display}`;
  }).join(' ');
  const base = raw.replace(/\n+$/u, '');

  if (base === '') {
    return suffix;
  }

  return `${base}\n\n${suffix}`;
}

export function isExistingPostEdit(composer) {
  if (!composer) {
    return false;
  }

  const id = composer.get('id');
  const scheduledStatusId = composer.get('scheduled_status_id');

  return (id !== null && id !== undefined) || (scheduledStatusId !== null && scheduledStatusId !== undefined);
}

export function materializeComposerText(composer) {
  if (!composer) {
    return '';
  }

  const text = composer.get('text', '') || '';

  if (isExistingPostEdit(composer)) {
    return text;
  }

  const hashtags = composer.getIn(['context', 'managed', 'hashtags']);
  const suppressed = composer.getIn(['context', 'suppressions', 'hashtags']);
  const active = [];

  if (hashtags && hashtags.forEach) {
    hashtags.forEach(tag => {
      const normalizedName = tag.get('normalizedName');

      if (!suppressed || !suppressed.includes(normalizedName)) {
        active.push({
          name: tag.get('name'),
          normalizedName,
        });
      }
    });
  }

  return materializeManagedHashtags(text, active);
}
