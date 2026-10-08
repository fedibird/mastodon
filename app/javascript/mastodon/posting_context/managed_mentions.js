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

const MENTION_PLACEMENTS = {
  prepend: true,
  append: true,
  after_title: true,
};

export function managedMentionPlacement(mention) {
  const placement = mention && (mention.get ? mention.get('placement') : mention.placement);

  return MENTION_PLACEMENTS[placement] ? placement : 'prepend';
}

const mentionToken = mention => `@${String(mention.acct).replace(/^@+/u, '')}`;

const mentionsWithPlacement = (mentions, placement) => (
  mentions.filter(mention => managedMentionPlacement(mention) === placement)
);

// Keep the first line, then insert the mention block at the start of the
// remainder. Leading blank lines in that remainder stay where they are.
const insertMentionsAfterTitle = (text, mentions) => {
  if (mentions.length === 0) {
    return text;
  }

  const block = mentions.map(mentionToken).join(' ');

  if (text === '') {
    return block;
  }

  const newline = text.indexOf('\n');

  if (newline === -1) {
    return `${text}\n${block}`;
  }

  const title = text.slice(0, newline);
  const body = text.slice(newline + 1);

  if (body === '') {
    return `${title}\n${block}`;
  }

  return `${title}\n${block}\n${body}`;
};

export function materializeManagedMentions(text, mentions) {
  const raw = text || '';
  const missing = (mentions || []).filter(mention => {
    const acct = mention && mention.acct;

    return acct && !textContainsMention(raw, acct);
  });

  if (missing.length === 0) {
    return raw;
  }

  const prepended = mentionsWithPlacement(missing, 'prepend');
  const afterTitle = mentionsWithPlacement(missing, 'after_title');
  const appended = mentionsWithPlacement(missing, 'append');
  let result = raw;

  if (prepended.length > 0) {
    const prefix = prepended.map(mentionToken).join(' ');

    result = result === '' ? prefix : `${prefix} ${result}`;
  }

  result = insertMentionsAfterTitle(result, afterTitle);

  if (appended.length > 0) {
    const suffix = appended.map(mentionToken).join(' ');

    if (result === '') {
      result = suffix;
    } else if (result.endsWith('\n')) {
      result = `${result}${suffix}`;
    } else {
      result = `${result}\n${suffix}`;
    }
  }

  return result;
}

// Lemmy uses the first line as a title. An empty line, or a line that is
// only mentions or hashtags, is a hint, not a send block.
export function firstLineLacksProse(text) {
  const line = String(text || '').split('\n')[0];

  if (line.trim() === '') {
    return true;
  }

  const mention = /@[A-Za-z0-9_]+(?:[A-Za-z0-9_.-]+[A-Za-z0-9_]+)?(?:@[\p{L}\p{M}\p{N}\p{Pc}_.-]+[\p{L}\p{M}\p{N}\p{Pc}_]+)?/gu;
  const hashtag = /[#＃][\p{L}\p{M}\p{N}\p{Pc}_][\p{L}\p{M}\p{N}\p{Pc}_·・\u200C]*/gu;
  const withoutMarkers = line.replace(mention, ' ').replace(hashtag, ' ');

  return withoutMarkers !== line && withoutMarkers.trim() === '';
}
