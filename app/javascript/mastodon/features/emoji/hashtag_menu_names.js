import { presentEmojiMutePlain } from './emoji_mute_text';

// While settings are unverified, a hashtag name that still contains a user
// emoji cannot sit in a DOM attribute. The menu keeps the original string
// here and the attribute carries only this token.
const namesByToken = new Map();
const tokensByName = new Map();
let sequence = 0;

const concealsName = (name, index) => {
  if (!name || !index || index.suppressAll !== true) {
    return false;
  }

  const shown = presentEmojiMutePlain(name, index);

  return typeof shown === 'string' && shown !== name;
};

export function hashtagMenuDomName(name, index) {
  if (!concealsName(name, index)) {
    return name;
  }

  const cached = tokensByName.get(name);

  if (cached) {
    return cached;
  }

  sequence += 1;
  const token = `hmtoken-${sequence}`;

  namesByToken.set(token, name);
  tokensByName.set(name, token);

  return token;
}

export function hashtagMenuStoredName(value) {
  if (namesByToken.has(value)) {
    return namesByToken.get(value);
  }

  return value || '';
}
