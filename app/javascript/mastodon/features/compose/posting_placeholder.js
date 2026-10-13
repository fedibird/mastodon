import { POSTING_PLACEHOLDERS } from './posting_placeholders';

const AUTO_LANGUAGE = new Set(['', 'und', 'auto', 'nil']);

export const isAutoPostingLanguage = language => {
  if (language === null || language === undefined) {
    return true;
  }

  return AUTO_LANGUAGE.has(String(language).trim().toLowerCase());
};

export const postingPlaceholderText = language => {
  if (isAutoPostingLanguage(language)) {
    return null;
  }

  const code = String(language).trim();
  if (POSTING_PLACEHOLDERS[code]) {
    return POSTING_PLACEHOLDERS[code];
  }

  const match = Object.keys(POSTING_PLACEHOLDERS).find(key => key.toLowerCase() === code.toLowerCase());

  return match ? POSTING_PLACEHOLDERS[match] : null;
};

export const textareaLanguage = language => (
  isAutoPostingLanguage(language) ? undefined : String(language).trim()
);
