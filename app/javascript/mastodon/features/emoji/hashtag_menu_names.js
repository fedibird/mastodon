import { presentEmojiMutePlain } from './emoji_mute_text';

// The original name stays on the live element. A detached node can be
// collected, so an account switch does not keep the previous viewer's tags.
const namesByElement = new WeakMap();

const concealsName = (name, index) => {
  if (!name || !index || index.suppressAll !== true) {
    return false;
  }

  const shown = presentEmojiMutePlain(name, index);

  return typeof shown === 'string' && shown !== name;
};

// The attribute the menu selector requires. A concealed name is an empty
// value plus data-menu-hashtag-token, never a string a real tag could share.
export function hashtagMenuDomName(name, index) {
  return concealsName(name, index) ? '' : name;
}

export function bindHashtagMenuName(element, name, index) {
  if (!element) {
    return hashtagMenuDomName(name, index);
  }

  if (!concealsName(name, index)) {
    namesByElement.delete(element);
    element.removeAttribute('data-menu-hashtag-token');
    return name;
  }

  namesByElement.set(element, name);
  element.setAttribute('data-menu-hashtag-token', '');

  return '';
}

// Only an element that opted into the token is resolved. A plain tag whose
// text happens to match some other token keeps that text.
export function hashtagMenuStoredName(element) {
  if (!element || typeof element.getAttribute !== 'function') {
    return '';
  }

  if (element.hasAttribute('data-menu-hashtag-token')) {
    return namesByElement.get(element) || '';
  }

  return element.getAttribute('data-menu-hashtag') || '';
}
