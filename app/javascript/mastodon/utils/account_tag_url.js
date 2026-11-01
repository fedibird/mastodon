// Match a clicked hashtag label to status.tags[].account_url.
// The server already built the URL. This only decides which tag it belongs to.
// Normalization is NFKC + case fold, the same first steps as HashtagNormalizer.
// ASCII folding is not repeated here: a label that does not land on exactly one
// tag yields null instead of a URL for a different tag.

export function hashtagKey(value) {
  return String(value || '').replace(/^[#＃]+/u, '').normalize('NFKC').toLocaleLowerCase();
}

function read(tag, field) {
  if (!tag) {
    return undefined;
  }

  if (typeof tag.get === 'function') {
    return tag.get(field);
  }

  return tag[field];
}

export function accountUrlForHashtag(tags, label) {
  if (!tags || typeof label !== 'string') {
    return null;
  }

  const key = hashtagKey(label);

  if (!key) {
    return null;
  }

  const list = typeof tags.toArray === 'function' ? tags.toArray() : Array.from(tags);
  let matched = false;
  let url = null;

  for (let i = 0; i < list.length; i += 1) {
    if (hashtagKey(read(list[i], 'name')) !== key) {
      continue;
    }

    const candidate = read(list[i], 'account_url') || null;

    if (matched && candidate !== url) {
      return null;
    }

    matched = true;
    url = candidate;
  }

  return matched ? url : null;
}
