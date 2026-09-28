const CHINESE_REGIONAL_SCRIPTS = {
  'zh-cn': 'zh-Hans',
  'zh-sg': 'zh-Hans',
  'zh-tw': 'zh-Hant',
  'zh-hk': 'zh-Hant',
  'zh-mo': 'zh-Hant',
};

const CHINESE_SCRIPT_TAGS = ['zh-Hans', 'zh-Hant'];

const normalizedLanguageTag = language => String(language || '').replace(/_/g, '-').toLowerCase();

const providerChineseScript = (normalized, translationLanguages) => (
  CHINESE_SCRIPT_TAGS.find(tag => tag.toLowerCase() === normalized && translationLanguages?.has(tag))
);

const bareChineseSourceLanguage = (language, translationLanguages) => {
  if (translationLanguages?.has('zh')) {
    return 'zh';
  }

  const chineseAvailable = CHINESE_SCRIPT_TAGS.some(tag => translationLanguages?.has(tag));
  if (chineseAvailable && translationLanguages?.has('und')) {
    return 'und';
  }

  return language;
};

// Same source resolution as TranslateStatusService. The public languages map
// exposes provider auto-detection as "und" rather than a nil key.
export const translationSourceLanguage = (language, translationLanguages) => {
  if (!language || translationLanguages?.has(language)) {
    return language;
  }

  const normalized = normalizedLanguageTag(language);

  if (normalized === 'zh') {
    return bareChineseSourceLanguage(language, translationLanguages);
  }

  const script = providerChineseScript(normalized, translationLanguages) || CHINESE_REGIONAL_SCRIPTS[normalized];
  if (script && translationLanguages?.has(script)) {
    return script;
  }

  const match = String(language).match(/^([A-Za-z]{2,3})[-_]([A-Za-z]{2}|\d{3})$/);
  if (!match) {
    return language;
  }

  const primary = match[1].toLowerCase();
  return translationLanguages?.has(primary) ? primary : language;
};

export const languageOption = (code, preloadedLanguages, unspecifiedName) => {
  if (!code || code === 'und') {
    return ['und', 'Unspecified', unspecifiedName];
  }

  const known = (preloadedLanguages || []).find(lang => lang[0] === code);
  return known || [code, code, code];
};

const addCode = (codes, seen, code) => {
  if (!code || seen.has(code)) {
    return;
  }

  seen.add(code);
  codes.push(code);
};

const byKnownLanguage = (preloadedLanguages) => {
  const order = new Map((preloadedLanguages || []).map((lang, index) => [lang[0], index]));

  return (left, right) => {
    if (left === 'und') {
      return -1;
    }

    if (right === 'und') {
      return 1;
    }

    const leftIndex = order.has(left) ? order.get(left) : Number.MAX_SAFE_INTEGER;
    const rightIndex = order.has(right) ? order.get(right) : Number.MAX_SAFE_INTEGER;

    if (leftIndex !== rightIndex) {
      return leftIndex - rightIndex;
    }

    return left.localeCompare(right);
  };
};

export const sourceLanguageOptions = (translationLanguages, currentSource, preloadedLanguages, unspecifiedName) => {
  const codes = [];
  const seen = new Set();

  if (translationLanguages?.has('und')) {
    addCode(codes, seen, 'und');
  }

  translationLanguages?.keySeq?.().forEach(key => {
    if (key && key !== 'und') {
      addCode(codes, seen, key);
    }
  });

  addCode(codes, seen, currentSource || 'und');
  codes.sort(byKnownLanguage(preloadedLanguages));

  return codes.map(code => languageOption(code, preloadedLanguages, unspecifiedName));
};

export const targetLanguageOptions = (translationLanguages, source, currentTarget, preloadedLanguages, unspecifiedName) => {
  const resolved = translationSourceLanguage(source, translationLanguages);
  const codes = [];
  const seen = new Set();
  const targets = translationLanguages?.get(resolved);

  targets?.forEach(code => addCode(codes, seen, code));
  addCode(codes, seen, currentTarget);

  return codes.map(code => languageOption(code, preloadedLanguages, unspecifiedName));
};

export const translationCapability = (status, viewerPair, translationLanguages, { loggedIn, privateContentAllowed }) => {
  const visibilityAllowsTranslation = ['public', 'unlisted'].includes(status.get('visibility')) || privateContentAllowed;
  const allowsRequest = !!loggedIn &&
    visibilityAllowsTranslation &&
    (status.get('search_index') || '').trim().length > 0;

  if (!allowsRequest) {
    return { allowsRequest: false, pairSupported: false };
  }

  const resolved = translationSourceLanguage(viewerPair.source, translationLanguages);
  const targets = translationLanguages?.get(resolved);

  return {
    allowsRequest: true,
    pairSupported: !!targets?.includes(viewerPair.target),
  };
};
