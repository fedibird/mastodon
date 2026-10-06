// Semantic comparison for managed mentions. NFKC plus case folding.
// Mention starts are ASCII "@" only, matching Account::MENTION_RE.
// Fullwidth "＠" is not a server mention. This is an internal Composer helper.
const WORD_CHAR = /[\p{L}\p{M}\p{N}\p{Pc}_]/u;
const USERNAME_RE = /^[A-Za-z0-9_]+(?:[A-Za-z0-9_.-]+[A-Za-z0-9_]+)?/;
const DOMAIN_RE = /^@(?:[\p{L}\p{M}\p{N}\p{Pc}_.-]+[\p{L}\p{M}\p{N}\p{Pc}_]+)/u;

export function normalizeManagedMentionAcct(acct) {
  return String(acct || '').replace(/^@+/u, '').normalize('NFKC').toLowerCase();
}

const isWordChar = char => WORD_CHAR.test(char);

const mentionAt = (source, index) => {
  if (source[index] !== '@') {
    return null;
  }

  if (index > 0) {
    const previous = source[index - 1];

    if (previous === '/' || isWordChar(previous)) {
      return null;
    }
  }

  const rest = source.slice(index + 1);
  const username = rest.match(USERNAME_RE);

  if (!username) {
    return null;
  }

  let acct = username[0];
  const domain = rest.slice(username[0].length).match(DOMAIN_RE);

  if (domain) {
    acct += domain[0];
  }

  return {
    acct,
    length: 1 + acct.length,
  };
};

export function textContainsMention(text, acct) {
  const normalized = normalizeManagedMentionAcct(acct);

  if (!normalized) {
    return false;
  }

  const source = String(text || '');
  let index = 0;

  while (index < source.length) {
    const found = mentionAt(source, index);

    if (found) {
      if (normalizeManagedMentionAcct(found.acct) === normalized) {
        return true;
      }

      index += found.length;
      continue;
    }

    index += 1;
  }

  return false;
}

export function materializeManagedMentions(text, mentions) {
  const raw = text || '';
  const missing = (mentions || []).filter(mention => {
    const acct = mention && mention.acct;

    return acct && !textContainsMention(raw, acct);
  });

  if (missing.length === 0) {
    return raw;
  }

  const prefix = missing.map(mention => `@${String(mention.acct).replace(/^@+/u, '')}`).join(' ');

  if (raw === '') {
    return prefix;
  }

  return `${prefix} ${raw}`;
}
