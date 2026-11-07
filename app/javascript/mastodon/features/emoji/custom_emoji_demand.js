const SHORTCODE = /:[A-Za-z0-9_]+:/;

export function textNeedsCustomEmojiCatalog(value) {
  return SHORTCODE.test(value === null || value === undefined ? '' : String(value));
}

export function valuesNeedCustomEmojiCatalog(values) {
  if (!values || typeof values.forEach !== 'function') {
    return false;
  }

  let needed = false;

  values.forEach(value => {
    if (!needed && textNeedsCustomEmojiCatalog(value)) {
      needed = true;
    }
  });

  return needed;
}
