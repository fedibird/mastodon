// Japanese labels used only when Intl.DisplayNames is available.
// ldn and zba come back as the code itself; zh-YUE is rejected as invalid.
// The Chinese regional codes already name the region in the native name, so
// the long CLDR region label is replaced with a short one.
const JAPANESE_LANGUAGE_NAME_OVERRIDES = {
  ldn: 'ラーダン語',
  zba: 'バライバラン語',
  'zh-CN': '中国語・中国',
  'zh-TW': '中国語・台湾',
  'zh-HK': '中国語・香港',
  'zh-YUE': '広東語',
};

const JAPANESE_SCRIPT = /[\u3040-\u30ff\u3400-\u9fff\uff66-\uff9d]/;

const displayNamesCache = new Map();
let cachedDisplayNamesConstructor = null;

const isJapaneseLocale = locale => /^ja(?:[-_]|$)/i.test(String(locale || ''));

const normalizeName = name => String(name || '').normalize('NFKC').replace(/\s+/g, ' ').trim().toLocaleLowerCase();

const namesEquivalent = (left, right) => {
  const normalizedLeft = normalizeName(left);
  const normalizedRight = normalizeName(right);

  return normalizedLeft !== '' && normalizedLeft === normalizedRight;
};

const sameAsCode = (name, code) => normalizeName(name) === normalizeName(code);

// ICU can answer "und" with the placeholder "root" instead of a language name.
const isPlaceholderDisplayName = name => normalizeName(name) === 'root';

const displayNamesFor = (locale) => {
  if (typeof Intl === 'undefined' || typeof Intl.DisplayNames !== 'function') {
    displayNamesCache.clear();
    cachedDisplayNamesConstructor = null;
    return null;
  }

  if (cachedDisplayNamesConstructor !== Intl.DisplayNames) {
    displayNamesCache.clear();
    cachedDisplayNamesConstructor = Intl.DisplayNames;
  }

  const key = String(locale);
  if (displayNamesCache.has(key)) {
    return displayNamesCache.get(key);
  }

  let displayNames = null;

  try {
    displayNames = new Intl.DisplayNames([key], { type: 'language' });
  } catch (_) {
    displayNames = null;
  }

  displayNamesCache.set(key, displayNames);
  return displayNames;
};

const readDisplayName = (displayNames, code) => {
  try {
    return displayNames.of(String(code));
  } catch (_) {
    return null;
  }
};

const acceptsDisplayName = (name, code, locale) => {
  if (!name || sameAsCode(name, code) || isPlaceholderDisplayName(name)) {
    return false;
  }

  if (isJapaneseLocale(locale) && !JAPANESE_SCRIPT.test(String(name).normalize('NFKC'))) {
    return false;
  }

  return true;
};

export const localizedCommonName = (code, englishName, locale) => {
  const fallback = englishName || '';

  if (!locale || code === undefined || code === null || String(code).trim() === '') {
    return fallback;
  }

  const displayNames = displayNamesFor(locale);
  // Without Intl.DisplayNames, keep the English common name for every code.
  // Overrides apply only when the API exists, so a missing implementation
  // does not mix Japanese and English names.
  if (!displayNames) {
    return fallback;
  }

  if (isJapaneseLocale(locale) && Object.prototype.hasOwnProperty.call(JAPANESE_LANGUAGE_NAME_OVERRIDES, code)) {
    return JAPANESE_LANGUAGE_NAME_OVERRIDES[code];
  }

  const resolved = readDisplayName(displayNames, code);
  if (acceptsDisplayName(resolved, code, locale)) {
    return String(resolved).normalize('NFKC').trim();
  }

  return fallback;
};

export const languageOptionParts = (language, locale) => {
  const code = language && language[0];
  const englishName = (language && language[1]) || '';
  const nativeName = (language && language[2]) || '';
  const commonName = localizedCommonName(code, englishName, locale);

  if (!nativeName) {
    return { nativeName: commonName, commonName: '' };
  }

  if (!commonName || namesEquivalent(nativeName, commonName)) {
    return { nativeName, commonName: '' };
  }

  return { nativeName, commonName };
};

export const languageMatches = (language, query, locale) => {
  const code = language && language[0];
  const englishName = language && language[1];
  const nativeName = language && language[2];
  const localizedName = localizedCommonName(code, englishName || '', locale);

  return [code, englishName, nativeName, localizedName].some(part => String(part || '').toLocaleLowerCase().includes(query));
};
